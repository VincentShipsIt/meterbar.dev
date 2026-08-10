import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Direct coverage for `CodexCliLocalService` without touching the network or a
/// real `CODEX_HOME/auth.json`:
///   - `mapUsageResponse` (the response → `UsageMetrics` mapping extracted from
///     `fetchUsageMetrics`) is exercised with decoded fixtures.
///   - the auth-file read + token-expiry gating is exercised through the
///     injected `authFileDataProvider` seam.
final class CodexCliLocalServiceTests: XCTestCase {

    // MARK: - Fixture helpers

    /// Builds an unsigned JWT (header.payload.signature) with the given claims.
    /// Only the payload is read by the app, so the header/signature are dummies.
    private func makeJWT(exp: TimeInterval?, accountId: String? = nil) -> String {
        var payload: [String: Any] = [:]
        if let exp { payload["exp"] = exp }
        if let accountId { payload["account_id"] = accountId }
        let header = base64URL(Data(#"{"alg":"none","typ":"JWT"}"#.utf8))
        let body = base64URL(try! JSONSerialization.data(withJSONObject: payload))
        return "\(header).\(body).sig"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func decodeResponse(_ json: String) throws -> CodexCliUsageResponse {
        try JSONDecoder().decode(CodexCliUsageResponse.self, from: Data(json.utf8))
    }

    // Far-future / past expiries expressed as fixed Unix seconds for determinism.
    private let futureExp: TimeInterval = 4_102_444_800 // 2100-01-01
    private let pastExp: TimeInterval = 1_000_000_000    // 2001-09-09

    // MARK: - Response mapping

    func testMapUsageResponseMapsAllThreeWindows() throws {
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 40.0,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 3600,
              "reset_at": 1735689600
            },
            "secondary_window": {
              "used_percent": 72.5,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 86400,
              "reset_at": 1736294400
            }
          },
          "code_review_rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 8.0,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 86400,
              "reset_at": 1736294400
            }
          },
          "rate_limit_reset_credits": { "available_count": 3 }
        }
        """
        let response = try decodeResponse(json)
        let metrics = CodexCliLocalService.mapUsageResponse(response)

        XCTAssertEqual(metrics.service, .codexCli)
        XCTAssertEqual(metrics.sessionLimit?.used, 40.0)
        XCTAssertEqual(metrics.sessionLimit?.total, 100.0)
        XCTAssertEqual(metrics.sessionLimit?.windowSeconds, 18000)
        XCTAssertEqual(metrics.sessionLimit?.resetTime, Date(timeIntervalSince1970: 1_735_689_600))
        XCTAssertEqual(metrics.weeklyLimit?.used, 72.5)
        XCTAssertEqual(metrics.weeklyLimit?.windowSeconds, 604800)
        XCTAssertEqual(metrics.codeReviewLimit?.used, 8.0)
        XCTAssertEqual(metrics.resetCreditsAvailable, 3)
    }

    func testMapUsageResponseFreeAccountHasNoWindows() throws {
        // Free accounts return a null rate_limit; the mapping must still surface
        // the extra-usage signal (here: unknown, since no credits object present).
        let json = """
        { "plan_type": "free", "rate_limit": null }
        """
        let response = try decodeResponse(json)
        let metrics = CodexCliLocalService.mapUsageResponse(response)

        XCTAssertNil(metrics.sessionLimit)
        XCTAssertNil(metrics.weeklyLimit)
        XCTAssertNil(metrics.codeReviewLimit)
        XCTAssertEqual(metrics.extraUsage?.state, .unknown)
    }

    func testMapUsageResponseWithSessionOnlyOmitsWeekly() throws {
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 12.0,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 3600,
              "reset_at": 1735689600
            }
          }
        }
        """
        let response = try decodeResponse(json)
        let metrics = CodexCliLocalService.mapUsageResponse(response)

        XCTAssertEqual(metrics.sessionLimit?.used, 12.0)
        XCTAssertNil(metrics.weeklyLimit)
    }

    func testMapUsageResponseWithWeeklyOnlyOmitsSession() throws {
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 36.0,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 540000,
              "reset_at": 1785880800
            }
          }
        }
        """
        let response = try decodeResponse(json)
        let metrics = CodexCliLocalService.mapUsageResponse(response)

        XCTAssertNil(metrics.sessionLimit)
        XCTAssertEqual(metrics.weeklyLimit?.used, 36.0)
        XCTAssertEqual(metrics.weeklyLimit?.windowSeconds, 604800)
    }

    // MARK: - Auth-file / token-expiry gating

    nonisolated private func authFileJSON(accessToken: String, accountId: String) -> Data {
        Data("""
        {
          "OPENAI_API_KEY": null,
          "tokens": {
            "id_token": "\(accessToken)",
            "access_token": "\(accessToken)",
            "refresh_token": "refresh",
            "account_id": "\(accountId)"
          },
          "last_refresh": "2026-07-01T00:00:00Z"
        }
        """.utf8)
    }

    func testGetAuthTokenReturnsUnexpiredToken() {
        let token = makeJWT(exp: futureExp)
        let service = CodexCliLocalService(authFileDataProvider: {
            self.authFileJSON(accessToken: token, accountId: "acc_1")
        })
        XCTAssertEqual(service.getAuthToken(), token)
        XCTAssertEqual(service.getAccountId(), "acc_1")
    }

    func testGetAuthTokenRejectsExpiredToken() {
        let token = makeJWT(exp: pastExp)
        let service = CodexCliLocalService(authFileDataProvider: {
            self.authFileJSON(accessToken: token, accountId: "acc_1")
        })
        XCTAssertNil(service.getAuthToken())
    }

    func testGetAuthTokenReturnsNilWhenAuthFileMissing() {
        let service = CodexCliLocalService(authFileDataProvider: { nil })
        XCTAssertNil(service.getAuthToken())
        XCTAssertNil(service.getAccountId())
    }

    func testGetAuthTokenReturnsNilForMalformedAuthFile() {
        let service = CodexCliLocalService(authFileDataProvider: { Data("not json".utf8) })
        XCTAssertNil(service.getAuthToken())
    }

    func testAccountAuthProviderReadsEachCodexHomeIndependently() {
        let defaultToken = makeJWT(exp: futureExp, accountId: "default")
        let workToken = makeJWT(exp: futureExp, accountId: "work")
        let work = CodexAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/codex-work")
        let service = CodexCliLocalService(accountAuthFileDataProvider: { account in
            if account.id == work.id {
                return self.authFileJSON(accessToken: workToken, accountId: "work")
            }
            return self.authFileJSON(accessToken: defaultToken, accountId: "default")
        })

        XCTAssertEqual(service.getAuthToken(account: .defaultAccount), defaultToken)
        XCTAssertEqual(service.getAccountId(account: .defaultAccount), "default")
        XCTAssertEqual(service.getAuthToken(account: work), workToken)
        XCTAssertEqual(service.getAccountId(account: work), "work")
    }

    // MARK: - Main-thread hygiene

    /// The auth-file read is disk I/O and must never run on the main thread when
    /// triggered through the async fetch path. The Xcode app target builds with
    /// default MainActor isolation, where an un-hopped read would land on main
    /// and beachball the UI (the SwiftPM test build is laxer — this pins the
    /// contract so the explicit off-main hop is not reverted).
    @MainActor
    func testFetchUsageMetricsReadsAuthFileOffMainThread() async {
        final class ThreadRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var sawMainThread = false
            private var callCount = 0
            func record() {
                lock.lock()
                defer { lock.unlock() }
                if Thread.isMainThread { sawMainThread = true }
                callCount += 1
            }
            var wasCalledOnMainThread: Bool {
                lock.lock()
                defer { lock.unlock() }
                return sawMainThread
            }
            var wasCalled: Bool {
                lock.lock()
                defer { lock.unlock() }
                return callCount > 0
            }
        }

        let recorder = ThreadRecorder()
        // No auth file → fetch throws notAuthenticated before any network call,
        // but only after consulting the provider (the part under test).
        let service = CodexCliLocalService(authFileDataProvider: {
            recorder.record()
            return nil
        })

        await Task.yield() // let the init-time detached checkAccess drain first

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("Expected notAuthenticated")
        } catch {
            // expected
        }

        XCTAssertTrue(recorder.wasCalled, "fetch must consult the auth file")
        XCTAssertFalse(
            recorder.wasCalledOnMainThread,
            "auth-file read ran on the main thread — blocking I/O must hop off main"
        )
    }

    // MARK: - Per-account error attribution

    /// `UsageDataManager` fans usage fetches out across every enabled Codex
    /// profile concurrently, so a fetch may only ever record its own profile's
    /// outcome: a shared `lastError` would leave whichever profile finished last
    /// speaking for all of them.

    private final class StubURLProtocol: URLProtocol {
        static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Smallest body the usage decoder accepts — the window math has its own
    /// fixtures above, these tests only care about success vs failure.
    private static let usageBody = Data(#"{"plan_type":"plus","rate_limit":null}"#.utf8)

    /// Serves 200 to the profiles named in `succeeding` and `failureStatus` to
    /// everyone else, keyed by the per-profile `ChatGPT-Account-Id` header.
    private func stubUsage(succeeding: Set<String>, failureStatus: Int) {
        StubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let accountID = request.value(forHTTPHeaderField: "ChatGPT-Account-Id") ?? ""
            let succeeds = succeeding.contains(accountID)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: succeeds ? 200 : failureStatus,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, succeeds ? Self.usageBody : Data())
        }
    }

    @MainActor
    func testConcurrentFetchesAttributeFailuresToTheOwningAccount() async {
        let token = makeJWT(exp: futureExp)
        let work = CodexAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/codex-work")
        // Only the default profile is signed in; the work profile has no auth
        // file, so its fetch fails while the default profile's succeeds.
        let service = CodexCliLocalService(
            accountAuthFileDataProvider: { account in
                account.isDefault
                    ? self.authFileJSON(accessToken: token, accountId: "account-default")
                    : nil
            },
            urlSession: makeStubSession()
        )
        stubUsage(succeeding: ["account-default"], failureStatus: 500)
        await Task.yield() // let the init-time detached checkAccess drain first

        async let defaultFetch = try? await service.fetchUsageMetrics(account: .defaultAccount)
        async let workFetch = try? await service.fetchUsageMetrics(account: work)
        let (defaultMetrics, workMetrics) = await (defaultFetch, workFetch)

        XCTAssertNotNil(defaultMetrics, "the signed-in default profile should have fetched usage")
        XCTAssertNil(workMetrics, "the signed-out work profile should have failed")
        XCTAssertEqual(
            service.firstError(for: [work])?.localizedDescription,
            ServiceError.notAuthenticated.localizedDescription
        )
        XCTAssertNil(
            service.firstError(for: [.defaultAccount]),
            "the default profile succeeded — it must not inherit the work profile's error"
        )
    }

    @MainActor
    func testDefaultAccountSuccessDoesNotClearASecondaryAccountsError() async throws {
        let token = makeJWT(exp: futureExp)
        let work = CodexAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/codex-work")
        let service = CodexCliLocalService(
            accountAuthFileDataProvider: { account in
                self.authFileJSON(
                    accessToken: token,
                    accountId: account.isDefault ? "account-default" : "account-work"
                )
            },
            urlSession: makeStubSession()
        )
        stubUsage(succeeding: ["account-default"], failureStatus: 500)
        await Task.yield()

        // The secondary profile fails first and the default profile succeeds
        // afterwards — the interleaving that used to blank the shared error.
        do {
            _ = try await service.fetchUsageMetrics(account: work)
            XCTFail("Expected the stubbed HTTP 500 to fail the work profile")
        } catch {
            XCTAssertEqual((error as? ServiceError)?.localizedDescription, "HTTP 500")
        }
        _ = try await service.fetchUsageMetrics(account: .defaultAccount)

        XCTAssertEqual(
            service.firstError(for: [work])?.localizedDescription,
            "HTTP 500",
            "a later success on another profile must not clear this profile's error"
        )
        XCTAssertNil(service.firstError(for: [.defaultAccount]))
        XCTAssertEqual(service.firstError(for: [.defaultAccount, work])?.localizedDescription, "HTTP 500")
    }

    @MainActor
    func testRecoveringAccountClearsOnlyItsOwnError() async throws {
        let token = makeJWT(exp: futureExp)
        let work = CodexAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/codex-work")
        let personal = CodexAccount(id: UUID(), name: "Personal", homeDirectory: "/tmp/codex-personal")
        let service = CodexCliLocalService(
            accountAuthFileDataProvider: { account in
                self.authFileJSON(
                    accessToken: token,
                    accountId: account.id == work.id ? "account-work" : "account-personal"
                )
            },
            urlSession: makeStubSession()
        )
        stubUsage(succeeding: [], failureStatus: 500)
        await Task.yield()

        for account in [work, personal] {
            do {
                _ = try await service.fetchUsageMetrics(account: account)
                XCTFail("Expected the stubbed HTTP 500 to fail \(account.name)")
            } catch {
                // expected
            }
        }

        // Only the work profile recovers.
        stubUsage(succeeding: ["account-work"], failureStatus: 500)
        _ = try await service.fetchUsageMetrics(account: work)

        XCTAssertNil(service.firstError(for: [work]), "the recovered profile's error should be cleared")
        XCTAssertEqual(
            service.firstError(for: [personal])?.localizedDescription,
            "HTTP 500",
            "one profile recovering must not clear another profile's error"
        )
    }
}
