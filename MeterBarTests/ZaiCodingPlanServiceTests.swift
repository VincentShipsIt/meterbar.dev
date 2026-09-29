import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class ZaiCodingPlanServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private nonisolated static let payload = Data(
        #"{"code":200,"success":true,"data":{"level":"pro","limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":12,"nextResetTime":1790003600000}]}}"#.utf8
    )

    private nonisolated final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func record(_ request: URLRequest) {
            lock.lock()
            stored.append(request)
            lock.unlock()
        }
    }

    private func makeService(
        apiKey: String? = "zai-key-secret",
        region: ZaiCodingPlanRegion = .international,
        recorder: Recorder = Recorder(),
        respond: @escaping @Sendable (URLRequest) throws -> Data = { _ in ZaiCodingPlanServiceTests.payload }
    ) -> (service: ZaiCodingPlanService, recorder: Recorder, keychain: KeychainManager) {
        let keychain = KeychainManager(
            backend: SeededKeychainBackend(),
            currentService: "test.zai.\(UUID().uuidString)",
            legacyServices: []
        )
        if let apiKey {
            XCTAssertTrue(keychain.save(key: ZaiCodingPlanService.keychainKey, value: apiKey))
        }
        let now = now
        let service = ZaiCodingPlanService(
            keychain: keychain,
            fetchData: { request in
                recorder.record(request)
                return try respond(request)
            },
            region: { region },
            now: { now }
        )
        return (service, recorder, keychain)
    }

    // MARK: - Request shape

    func testInternationalRequestTargetsOnlyTheOfficialQuotaEndpoint() async throws {
        let (service, recorder, _) = makeService(region: .international)

        let metrics = try await service.fetchUsageMetrics()

        XCTAssertEqual(metrics.sessionLimit?.used, 12)
        let requests = recorder.requests
        XCTAssertEqual(requests.count, 1, "model-usage and tool-usage are never called")
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.z.ai/api/monitor/usage/quota/limit")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.url?.query)
    }

    func testMainlandRequestTargetsBigmodel() async throws {
        let (service, recorder, _) = makeService(region: .mainland)

        _ = try await service.fetchUsageMetrics()

        XCTAssertEqual(
            recorder.requests.first?.url?.absoluteString,
            "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
        )
    }

    func testRequestCarriesOnlyTheKeyAcceptAndAcceptLanguage() async throws {
        let (service, recorder, _) = makeService()

        _ = try await service.fetchUsageMetrics()

        let request = try XCTUnwrap(recorder.requests.first)
        let headerNames = Set((request.allHTTPHeaderFields ?? [:]).keys)
        XCTAssertEqual(headerNames, ["Authorization", "Accept", "Accept-Language"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "zai-key-secret")
    }

    func testRegionsAreAClosedSetOfDocumentedHosts() {
        XCTAssertEqual(ZaiCodingPlanRegion.allCases.map(\.host), ["api.z.ai", "open.bigmodel.cn"])
        for region in ZaiCodingPlanRegion.allCases {
            XCTAssertEqual(region.quotaLimitURL?.scheme, "https")
            XCTAssertEqual(region.quotaLimitURL?.host, region.host)
        }
        XCTAssertNil(ZaiCodingPlanRegion(rawValue: "https://evil.example"))
    }

    // MARK: - Credentials and failures

    func testNoKeyIsNotAuthenticatedWithoutNetwork() async {
        let (service, recorder, _) = makeService(apiKey: nil)

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected notAuthenticated")
        } catch ServiceError.notAuthenticated {
            let sent = recorder.requests
            XCTAssertTrue(sent.isEmpty)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testRejectedKeyClearsAccessUntilItIsReplaced() async throws {
        let (service, _, _) = makeService { _ in throw ServiceError.notAuthenticated }
        XCTAssertTrue(service.hasAccess)

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected notAuthenticated")
        } catch ServiceError.notAuthenticated {
            XCTAssertFalse(service.hasAccess, "a rejected key must stop reading as connected")
            XCTAssertTrue(service.hasAPIKey)
        }

        XCTAssertTrue(service.saveAPIKey("replacement-key"))
        XCTAssertTrue(service.hasAccess)
        XCTAssertNil(service.lastError)
    }

    func testAuthFailureInsideA200EnvelopeAlsoClearsAccess() async {
        let (service, _, _) = makeService { _ in Data(#"{"code":401,"success":false,"msg":"token expired"}"#.utf8) }

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected notAuthenticated")
        } catch ServiceError.notAuthenticated {
            XCTAssertFalse(service.hasAccess)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testFormatDriftIsAParsingErrorAndKeepsAccess() async {
        let (service, _, _) = makeService { _ in Data(#"{"code":200,"success":true,"data":{"shape":"changed"}}"#.utf8) }

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected a parsing error")
        } catch ServiceError.parsingError {
            XCTAssertTrue(service.hasAccess, "drift is not a credential problem")
            XCTAssertNotNil(service.lastError)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testErrorsNeverCarryTheKeyOrProviderBody() async {
        let (service, _, _) = makeService(apiKey: "zai-fixture-key-value") { request in
            throw ServiceError.apiError("boom \(request.value(forHTTPHeaderField: "Authorization") ?? "") {\"raw\":\"body\"}")
        }

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected a failure")
        } catch {
            let text = ServiceSupport.safeErrorMessage(for: error)
            XCTAssertFalse(text.contains("zai-fixture-key-value"))
            XCTAssertFalse(text.contains("raw"))
            XCTAssertFalse(service.lastError?.localizedDescription.contains("zai-fixture-key-value") ?? false)
        }
    }

    func testPlanTierIsRecordedForSettingsAndClearedWithTheKey() async throws {
        let (service, _, _) = makeService()

        _ = try await service.fetchUsageMetrics()
        XCTAssertEqual(service.planName, "pro")

        service.removeAPIKey()
        XCTAssertNil(service.planName)
        XCTAssertFalse(service.hasAccess)
    }

    func testSaveTrimsAndRejectsEmptyKeys() {
        let (service, _, keychain) = makeService(apiKey: nil)

        XCTAssertFalse(service.saveAPIKey("  \n"))
        XCTAssertFalse(service.hasAPIKey)
        XCTAssertTrue(service.saveAPIKey("  zai-key \n"))
        XCTAssertEqual(keychain.get(key: ZaiCodingPlanService.keychainKey), "zai-key")
    }
}
