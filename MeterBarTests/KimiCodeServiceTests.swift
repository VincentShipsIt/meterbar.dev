import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class KimiCodeServiceTests: XCTestCase {
    private var home: URL!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private nonisolated static let payload = Data(
        #"{"usages":{"limit_5h":{"used_ratio":0.3,"reset_time":"2026-09-11T18:00:00Z"},"limit_7d":{"used_ratio":0.2}}}"#.utf8
    )

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("KimiCodeServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    /// Records every request the service sends, so a test can assert exactly
    /// what left the process.
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

    private func writeCredential(_ json: String) throws {
        let directory = home.appendingPathComponent(".kimi-code/credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appendingPathComponent("kimi-code.json"))
    }

    private func makeService(
        apiKey: String? = nil,
        recorder: Recorder = Recorder(),
        respond: @escaping @Sendable (URLRequest) throws -> Data = { _ in KimiCodeServiceTests.payload }
    ) -> (service: KimiCodeService, recorder: Recorder, keychain: KeychainManager) {
        let keychain = KeychainManager(
            backend: SeededKeychainBackend(),
            currentService: "test.kimi.\(UUID().uuidString)",
            legacyServices: []
        )
        if let apiKey {
            XCTAssertTrue(keychain.save(key: KimiCodeService.keychainKey, value: apiKey))
        }
        let now = now
        let service = KimiCodeService(
            keychain: keychain,
            fetchData: { request in
                recorder.record(request)
                return try respond(request)
            },
            environment: [:],
            realHomeDirectory: home.path,
            now: { now }
        )
        return (service, recorder, keychain)
    }

    private func bearer(_ request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: "Authorization")
    }

    // MARK: - Request shape

    func testRequestIsTheCanonicalUsageEndpointWithOnlyAuthAndAcceptHeaders() async throws {
        try writeCredential(#"{"access_token":"tok-oauth","expires_at":1790003600}"#)
        let (service, recorder, _) = makeService()

        let metrics = try await service.fetchUsageMetrics()

        XCTAssertEqual(metrics.service, .kimiCode)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://api.kimi.com/coding/v1/usages")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        let headerNames = Set((request.allHTTPHeaderFields ?? [:]).keys)
        XCTAssertEqual(headerNames, ["Authorization", "Accept"], "no prompt, code, account, or identity payload rides along")
        XCTAssertEqual(bearer(request), "Bearer tok-oauth")
        XCTAssertNil(service.lastError)
    }

    func testTransportIsTheSharedEphemeralUsageSession() {
        let session = ServiceSupport.makeUsageSession()
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertNil(session.configuration.urlCredentialStorage)
    }

    // MARK: - Credential order

    func testOfficialSignInIsPreferredOverAnAPIKey() async throws {
        try writeCredential(#"{"access_token":"tok-oauth","expires_at":1790003600}"#)
        let (service, recorder, _) = makeService(apiKey: "key-secret")

        _ = try await service.fetchUsageMetrics()

        XCTAssertEqual(recorder.requests.map(bearer), ["Bearer tok-oauth"])
    }

    func testRejectedSignInFallsBackToTheAPIKeyOnce() async throws {
        try writeCredential(#"{"access_token":"tok-oauth","expires_at":1790003600}"#)
        let (service, recorder, _) = makeService(apiKey: "key-secret") { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-oauth" {
                throw ServiceError.notAuthenticated
            }
            return KimiCodeServiceTests.payload
        }

        let metrics = try await service.fetchUsageMetrics()

        XCTAssertEqual(metrics.sessionLimit?.used ?? -1, 30, accuracy: 0.0001)
        XCTAssertEqual(recorder.requests.map(bearer), ["Bearer tok-oauth", "Bearer key-secret"])
    }

    func testExpiredSignInIsSkippedWithoutANetworkCallAndTheKeyIsUsed() async throws {
        try writeCredential(#"{"access_token":"tok-old","expires_at":1789999999}"#)
        let (service, recorder, _) = makeService(apiKey: "key-secret")

        _ = try await service.fetchUsageMetrics()

        XCTAssertEqual(recorder.requests.map(bearer), ["Bearer key-secret"])
    }

    func testExpiredSignInWithoutAKeyNeedsAReconnectAndSendsNothing() async throws {
        try writeCredential(#"{"access_token":"tok-old","expires_at":1789999999}"#)
        let (service, recorder, _) = makeService()

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected notAuthenticated")
        } catch ServiceError.notAuthenticated {
            // reconnect guidance comes from readiness; the service just refuses
        }
        let sent = recorder.requests
        XCTAssertTrue(sent.isEmpty, "an expired token is never sent")
        XCTAssertNotNil(service.lastError)
    }

    func testBothCredentialsRejectedReportsNotAuthenticated() async throws {
        try writeCredential(#"{"access_token":"tok-oauth"}"#)
        let (service, recorder, _) = makeService(apiKey: "key-secret") { _ in throw ServiceError.notAuthenticated }

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected notAuthenticated")
        } catch ServiceError.notAuthenticated {
            XCTAssertEqual(recorder.requests.count, 2)
        }
    }

    func testNoCredentialsIsNotAuthenticatedWithoutNetwork() async {
        let (service, recorder, _) = makeService()

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected notAuthenticated")
        } catch ServiceError.notAuthenticated {
            XCTAssertTrue(recorder.requests.isEmpty)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAPIKeyAloneIsSufficient() async throws {
        let (service, recorder, _) = makeService(apiKey: "key-secret")

        _ = try await service.fetchUsageMetrics()

        XCTAssertEqual(recorder.requests.map(bearer), ["Bearer key-secret"])
    }

    // MARK: - Failure honesty and redaction

    func testUnreadablePayloadIsAParsingErrorNotZeroPercent() async {
        let (service, _, _) = makeService(apiKey: "key-secret") { _ in Data(#"{"nothing":"useful"}"#.utf8) }

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected a parsing error")
        } catch ServiceError.parsingError {
            XCTAssertNotNil(service.lastError)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testErrorsNeverCarryTheCredentialOrProviderBody() async {
        let (service, _, _) = makeService(apiKey: "key-secret-123") { request in
            throw ServiceError.apiError("boom \(request.value(forHTTPHeaderField: "Authorization") ?? "") {\"raw\":\"body\"}")
        }

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected a failure")
        } catch {
            let text = ServiceSupport.safeErrorMessage(for: error)
            XCTAssertFalse(text.contains("key-secret-123"))
            XCTAssertFalse(text.contains("raw"))
            XCTAssertFalse(service.lastError?.localizedDescription.contains("key-secret-123") ?? false)
        }
    }

    func testHTTPFailureKeepsOnlyTheStatusCode() async {
        let (service, _, _) = makeService(apiKey: "key-secret") { _ in throw ServiceError.apiError("HTTP 404") }

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(service.lastError?.localizedDescription, "HTTP 404")
        }
    }

    // MARK: - Access and key management

    func testHasAccessFollowsTheSignInFileOrTheKey() throws {
        let (none, _, _) = makeService()
        XCTAssertFalse(none.hasAccess)

        let (withKey, _, _) = makeService(apiKey: "key-secret")
        XCTAssertTrue(withKey.hasAccess)
        XCTAssertTrue(withKey.hasAPIKey)

        try writeCredential(#"{"access_token":"tok"}"#)
        let (withFile, _, _) = makeService()
        XCTAssertTrue(withFile.hasAccess)
        XCTAssertFalse(withFile.hasAPIKey)
    }

    func testCredentialProbeReportsOutcomeOnly() throws {
        let (service, _, _) = makeService()
        XCTAssertEqual(service.credentialProbe(), .notFound)

        try writeCredential(#"{"access_token":"tok","expires_at":1790003600}"#)
        XCTAssertEqual(service.credentialProbe(), .ready)

        try writeCredential(#"{"access_token":"tok","expires_at":1}"#)
        XCTAssertEqual(service.credentialProbe(), .expired)
    }

    func testSaveTrimsAndRejectsEmptyKeysAndRemoveClearsThem() {
        let (service, _, keychain) = makeService()

        XCTAssertFalse(service.saveAPIKey("   "))
        XCTAssertFalse(service.hasAPIKey)

        XCTAssertTrue(service.saveAPIKey("  key-secret \n"))
        XCTAssertEqual(keychain.get(key: KimiCodeService.keychainKey), "key-secret")

        XCTAssertTrue(service.removeAPIKey())
        XCTAssertFalse(service.hasAPIKey)
    }
}
