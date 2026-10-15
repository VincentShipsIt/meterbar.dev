import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class ClaudePlatformServiceTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-13T00:00:00Z") ?? Date()
    private let apiOrg = "22222222-2222-4222-8222-222222222222"
    private let otherOrg = "33333333-3333-4333-8333-333333333333"
    private var settingsDirectory: URL!

    override func setUpWithError() throws {
        settingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-platform-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: settingsDirectory)
    }

    private nonisolated final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        var paths: [String] { requests.compactMap { $0.url?.path } }

        func record(_ request: URLRequest) {
            lock.lock()
            stored.append(request)
            lock.unlock()
        }
    }

    private nonisolated static func organizations(_ entries: [(String, String, [String])]) -> Data {
        let body = entries.map { id, name, capabilities in
            let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
            return "{\"uuid\":\"\(id)\",\"name\":\"\(name)\",\"capabilities\":[\(caps)]}"
        }.joined(separator: ",")
        return Data("[\(body)]".utf8)
    }

    private nonisolated static let credits = Data("""
    {"amount":18725,"currency":"USD","balance":{"credits":{"amount_minor":18725,"exponent":2}},
     "promo_tranches":[{"remaining_amount_minor_units":12475,"granted_amount_minor_units":20000,
       "expires_at":"2026-10-28T00:00:00Z","program_id":"subscription_api_credit","name":"API credit (Max 20x)"}],
     "tranches":[{"remaining_amount_minor_units":6250,"granted_amount_minor_units":10000,
       "expires_at":"2027-05-01T00:00:00Z","program_id":"api_credits","name":null}]}
    """.utf8)

    private func makeService(
        sessionKey: String? = "sk-ant-sid01-secretvalue",
        recorder: Recorder = Recorder(),
        respond: @escaping @Sendable (URLRequest) throws -> ClaudePlatformService.Response
    ) -> (service: ClaudePlatformService, recorder: Recorder, keychain: KeychainManager) {
        let keychain = KeychainManager(
            backend: SeededKeychainBackend(),
            currentService: "test.claudeplatform.\(UUID().uuidString)",
            legacyServices: []
        )
        if let sessionKey {
            XCTAssertTrue(keychain.save(key: ClaudePlatformService.keychainKey, value: sessionKey))
        }
        let now = now
        let service = ClaudePlatformService(
            keychain: keychain,
            fetch: { request in
                recorder.record(request)
                return try respond(request)
            },
            settingsDirectory: settingsDirectory,
            now: { now }
        )
        return (service, recorder, keychain)
    }

    private nonisolated static func ok(_ data: Data) -> ClaudePlatformService.Response {
        ClaudePlatformService.Response(data: data, statusCode: 200)
    }

    private nonisolated static func status(_ code: Int) -> ClaudePlatformService.Response {
        ClaudePlatformService.Response(data: Data(#"{"error":"body must not leak"}"#.utf8), statusCode: code)
    }

    /// The healthy account: organizations, credits and spend.
    private func healthy(_ request: URLRequest) throws -> ClaudePlatformService.Response {
        let path = request.url?.path ?? ""
        if path == "/api/organizations" {
            return Self.ok(Self.organizations([
                ("11111111-1111-4111-8111-111111111111", "Chat Org", ["chat"]),
                (apiOrg, "API Org", ["api"])
            ]))
        }
        if path.hasSuffix("/prepaid/credits") { return Self.ok(Self.credits) }
        if path.hasSuffix("/current_spend") { return Self.ok(Data(#"{"amount":4321}"#.utf8)) }
        return Self.status(404)
    }

    // MARK: - Request shape

    func testReadsOnlyTheThreeConsoleEndpointsForTheApiOrganization() async throws {
        let (service, recorder, _) = makeService(respond: healthy)

        let metrics = try await service.fetchUsageMetrics()

        XCTAssertEqual(metrics.service, .claudePlatform)
        XCTAssertEqual(metrics.weeklyLimit?.total ?? 0, 200, accuracy: 0.0001)
        XCTAssertEqual(recorder.paths, [
            "/api/organizations",
            "/api/organizations/\(apiOrg)/prepaid/credits",
            "/api/organizations/\(apiOrg)/current_spend"
        ])
        for request in recorder.requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "platform.claude.com")
            XCTAssertNil(request.url?.query)
            XCTAssertFalse(request.httpShouldHandleCookies)
        }
    }

    func testRequestCarriesOnlyTheSessionKeyCookieAndBrowserHeaders() async throws {
        let (service, recorder, _) = makeService(respond: healthy)

        _ = try await service.fetchUsageMetrics()

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sessionKey=sk-ant-sid01-secretvalue")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://platform.claude.com")
    }

    func testOrganizationIDsAreValidatedBeforeTheyEnterAPath() async {
        let (service, recorder, _) = makeService { request in
            Self.ok(Self.organizations([("../admin", "Evil", ["api"])]))
        }

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected a parse failure")
        } catch ServiceError.parsingError {
            XCTAssertEqual(recorder.paths, ["/api/organizations"])
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Account shapes

    func testChatOnlyAccountIsAnAnswerNotAFailure() async throws {
        let (service, recorder, _) = makeService { _ in
            Self.ok(Self.organizations([("11111111-1111-4111-8111-111111111111", "Chat", ["chat"])]))
        }

        let metrics = try await service.fetchUsageMetrics()

        XCTAssertFalse(metrics.hasData)
        XCTAssertEqual(recorder.paths, ["/api/organizations"])
        XCTAssertEqual(service.support, .noAPIOrganization)
        XCTAssertNil(service.lastError)
        XCTAssertTrue(service.hasAccess)
        XCTAssertNotNil(service.statusNote)
        XCTAssertEqual(ClaudePlatformSupportSetting.load(directory: settingsDirectory), .noAPIOrganization)
    }

    func testForbiddenOrganizationFallsThroughToTheNextReadableOne() async throws {
        let (service, recorder, _) = makeService { [apiOrg, otherOrg] request in
            let path = request.url?.path ?? ""
            if path == "/api/organizations" {
                return Self.ok(Self.organizations([(apiOrg, "Member", ["api"]), (otherOrg, "Owner", ["api"])]))
            }
            if path == "/api/organizations/\(apiOrg)/prepaid/credits" { return Self.status(403) }
            if path.hasSuffix("/prepaid/credits") { return Self.ok(Self.credits) }
            return Self.ok(Data(#"{"amount":100}"#.utf8))
        }

        let metrics = try await service.fetchUsageMetrics()

        XCTAssertTrue(metrics.hasData)
        XCTAssertEqual(recorder.paths, [
            "/api/organizations",
            "/api/organizations/\(apiOrg)/prepaid/credits",
            "/api/organizations/\(otherOrg)/prepaid/credits",
            "/api/organizations/\(otherOrg)/current_spend"
        ])
        XCTAssertEqual(service.support, .readable)
        XCTAssertTrue(service.hasAccess)
    }

    func testEveryApiOrganizationForbiddenReportsBillingDeniedWithoutRejectingTheSession() async throws {
        let (service, _, _) = makeService { [apiOrg] request in
            let path = request.url?.path ?? ""
            if path == "/api/organizations" { return Self.ok(Self.organizations([(apiOrg, "Member", ["api"])])) }
            return Self.status(403)
        }

        let metrics = try await service.fetchUsageMetrics()

        XCTAssertFalse(metrics.hasData)
        XCTAssertEqual(service.support, .billingAccessDenied)
        XCTAssertTrue(service.hasAccess, "billing access is not a credential problem")
    }

    func testSpendFailureKeepsTheBalance() async throws {
        let (service, _, _) = makeService { [apiOrg] request in
            let path = request.url?.path ?? ""
            if path == "/api/organizations" { return Self.ok(Self.organizations([(apiOrg, "Org", ["api"])])) }
            if path.hasSuffix("/prepaid/credits") { return Self.ok(Self.credits) }
            return Self.status(500)
        }

        let metrics = try await service.fetchUsageMetrics()

        XCTAssertTrue(metrics.hasData)
        let note = try XCTUnwrap(service.balanceNote)
        XCTAssertTrue(note.contains("$187.25"), note)
        XCTAssertFalse(note.contains("This month"), note)
    }

    func testBalanceNoteCarriesBalanceSpendAndUTCExpiry() async throws {
        let (service, _, _) = makeService(respond: healthy)

        _ = try await service.fetchUsageMetrics()

        let note = try XCTUnwrap(service.balanceNote)
        XCTAssertTrue(note.contains("Balance $187.25"), note)
        XCTAssertTrue(note.contains("This month $43.21"), note)
        XCTAssertTrue(note.contains("Oct 28 (UTC)"), note)
    }

    // MARK: - Credentials and failures

    func testNoSessionIsNotAuthenticatedWithoutNetwork() async {
        let (service, recorder, _) = makeService(sessionKey: nil) { _ in Self.status(500) }

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected notAuthenticated")
        } catch ServiceError.notAuthenticated {
            XCTAssertTrue(recorder.requests.isEmpty)
            XCTAssertFalse(service.hasAccess)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testRejectedSessionClearsAccessUntilReplaced() async throws {
        for code in [401, 403] {
            let (service, _, _) = makeService { _ in Self.status(code) }
            XCTAssertTrue(service.hasAccess)

            do {
                _ = try await service.fetchUsageMetrics()
                XCTFail("expected notAuthenticated for \(code)")
            } catch ServiceError.notAuthenticated {
                XCTAssertFalse(service.hasAccess)
                XCTAssertTrue(service.hasSessionKey)
            }

            XCTAssertTrue(service.saveSessionKey("sessionKey=sk-ant-replacement"))
            XCTAssertTrue(service.hasAccess)
            XCTAssertNil(service.lastError)
        }
    }

    func testUnauthorizedCreditRequestAlsoRejectsTheSession() async {
        let (service, _, _) = makeService { [apiOrg] request in
            let path = request.url?.path ?? ""
            if path == "/api/organizations" { return Self.ok(Self.organizations([(apiOrg, "Org", ["api"])])) }
            return Self.status(401)
        }

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected notAuthenticated")
        } catch ServiceError.notAuthenticated {
            XCTAssertFalse(service.hasAccess)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testRateLimitAndOutageSurfaceOnlyTheStatusCodeAndKeepAccess() async {
        for code in [429, 503] {
            let (service, _, _) = makeService { _ in Self.status(code) }

            do {
                _ = try await service.fetchUsageMetrics()
                XCTFail("expected an error for \(code)")
            } catch {
                let text = ServiceSupport.safeErrorMessage(for: error)
                XCTAssertEqual(text, "HTTP \(code)")
                XCTAssertFalse(text.contains("leak"))
                XCTAssertTrue(service.hasAccess)
            }
        }
    }

    func testFormatDriftIsAParsingErrorAndKeepsAccess() async {
        let (service, _, _) = makeService { [apiOrg] request in
            let path = request.url?.path ?? ""
            if path == "/api/organizations" { return Self.ok(Self.organizations([(apiOrg, "Org", ["api"])])) }
            return Self.ok(Data(#"{"shape":"changed"}"#.utf8))
        }

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected a parsing error")
        } catch ServiceError.parsingError {
            XCTAssertTrue(service.hasAccess)
            XCTAssertNotNil(service.lastError)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testErrorsNeverCarryTheSessionOrProviderBody() async {
        let (service, _, _) = makeService(sessionKey: "sk-ant-sid01-fixture-secret") { request in
            throw ServiceError.apiError(
                "boom \(request.value(forHTTPHeaderField: "Cookie") ?? "") {\"raw\":\"body\"}"
            )
        }

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected a failure")
        } catch {
            let text = ServiceSupport.safeErrorMessage(for: error)
            XCTAssertFalse(text.contains("fixture-secret"))
            XCTAssertFalse(text.contains("raw"))
            XCTAssertFalse(service.lastError?.localizedDescription.contains("fixture-secret") ?? false)
        }
    }

    func testSessionLivesInTheKeychainNotInTheSharedSettings() async throws {
        let (service, _, _) = makeService(respond: healthy)

        _ = try await service.fetchUsageMetrics()

        let files = try FileManager.default.contentsOfDirectory(atPath: settingsDirectory.path)
        for name in files {
            let text = (try? String(contentsOf: settingsDirectory.appendingPathComponent(name), encoding: .utf8)) ?? ""
            XCTAssertFalse(text.contains("secretvalue"), name)
            XCTAssertFalse(text.contains("187.25"), "billing figures stay in memory: \(name)")
        }
    }

    func testSaveKeepsOnlyTheSessionKeyAndRejectsUnusableInput() {
        let (service, _, keychain) = makeService(sessionKey: nil) { _ in Self.status(500) }

        XCTAssertFalse(service.saveSessionKey("  \n"))
        XCTAssertFalse(service.saveSessionKey("foo=1; bar=2"))
        XCTAssertFalse(service.hasSessionKey)
        XCTAssertTrue(service.saveSessionKey("Cookie: a=1; sessionKey=sk-ant-keep; b=2"))
        XCTAssertEqual(keychain.get(key: ClaudePlatformService.keychainKey), "sk-ant-keep")
    }

    func testRemovingTheSessionClearsAccessAndClassification() async throws {
        let (service, _, _) = makeService(respond: healthy)
        _ = try await service.fetchUsageMetrics()
        XCTAssertNotNil(service.balanceNote)

        service.removeSessionKey()

        XCTAssertFalse(service.hasAccess)
        XCTAssertNil(service.balanceNote)
        XCTAssertNil(service.support)
        XCTAssertNil(ClaudePlatformSupportSetting.load(directory: settingsDirectory))
    }

    func testExpiryTextIsTheUTCCalendarDate() {
        let date = ISO8601DateFormatter().date(from: "2026-10-28T00:00:00Z") ?? Date()
        XCTAssertEqual(ClaudePlatformService.expiryText(date), "Oct 28 (UTC)")
    }
}
