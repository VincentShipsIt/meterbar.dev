import XCTest
import MeterBarShared
@testable import MeterBar

/// Tests for parsing and carrying Codex "banked rate-limit resets" — the
/// `rate_limit_reset_credits.available_count` field on the wham/usage payload,
/// surfaced in the UI as "N reset available".
final class CodexResetCreditsTests: XCTestCase {
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

    private func decode(_ json: String) throws -> CodexCliUsageResponse {
        try JSONDecoder().decode(CodexCliUsageResponse.self, from: Data(json.utf8))
    }

    func testDecodesAvailableResetCount() throws {
        let response = try decode(#"""
        { "plan_type": "pro", "rate_limit": null, "rate_limit_reset_credits": { "available_count": 1 } }
        """#)
        XCTAssertEqual(response.resetCreditsAvailable, 1)
    }

    func testAbsentResetCreditsIsNil() throws {
        let response = try decode(#"{ "plan_type": "pro", "rate_limit": null }"#)
        XCTAssertNil(response.resetCreditsAvailable)
    }

    func testNullResetCreditsIsNil() throws {
        let response = try decode(#"{ "plan_type": "pro", "rate_limit_reset_credits": null }"#)
        XCTAssertNil(response.resetCreditsAvailable)
    }

    func testNullAvailableCountIsNil() throws {
        let response = try decode(#"{ "plan_type": "pro", "rate_limit_reset_credits": { "available_count": null } }"#)
        XCTAssertNil(response.resetCreditsAvailable)
    }

    /// Mirrors the real wham/usage payload, including fields the app does not model
    /// (`additional_rate_limits`, `spend_control`, `promo`) to prove forward-compatible
    /// decoding doesn't break when ChatGPT adds keys.
    func testDecodesAlongsideUnknownFields() throws {
        let response = try decode(#"""
        {
          "plan_type": "pro",
          "rate_limit": {
            "allowed": true, "limit_reached": false,
            "primary_window": { "used_percent": 0, "limit_window_seconds": 18000, "reset_after_seconds": 18000, "reset_at": 1781959611 },
            "secondary_window": { "used_percent": 35, "limit_window_seconds": 604800, "reset_after_seconds": 426296, "reset_at": 1782367907 }
          },
          "additional_rate_limits": [ { "limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox", "rate_limit": null } ],
          "credits": { "has_credits": false, "unlimited": false, "overage_limit_reached": false, "balance": "0" },
          "spend_control": { "reached": false, "individual_limit": null },
          "promo": null,
          "rate_limit_reset_credits": { "available_count": 1 }
        }
        """#)
        XCTAssertEqual(response.resetCreditsAvailable, 1)
        XCTAssertEqual(response.rateLimit?.secondaryWindow?.usedPercent, 35)
    }

    func testUsageMetricsCarriesResetCredits() {
        let metrics = UsageMetrics(service: .codexCli, resetCreditsAvailable: 2)
        XCTAssertEqual(metrics.resetCreditsAvailable, 2)

        // withExtraUsage must preserve the reset-credit count alongside the new status.
        let updated = metrics.withExtraUsage(.unknown)
        XCTAssertEqual(updated.resetCreditsAvailable, 2)
        XCTAssertEqual(updated.extraUsage, .unknown)
    }

    func testUsageMetricsResetCreditsDefaultsNil() {
        XCTAssertNil(UsageMetrics(service: .claudeCode).resetCreditsAvailable)
    }

    func testActionEligibilityRequiresBlockedCreditsAndAuthentication() {
        XCTAssertTrue(CodexResetCreditEligibility.isEligible(
            isBlocked: true,
            availableCredits: 1,
            isAuthenticated: true,
            hasResolvedAccount: true
        ))
        XCTAssertFalse(CodexResetCreditEligibility.isEligible(
            isBlocked: false,
            availableCredits: 1,
            isAuthenticated: true,
            hasResolvedAccount: true
        ))
        XCTAssertFalse(CodexResetCreditEligibility.isEligible(
            isBlocked: true,
            availableCredits: 0,
            isAuthenticated: true,
            hasResolvedAccount: true
        ))
        XCTAssertFalse(CodexResetCreditEligibility.isEligible(
            isBlocked: true,
            availableCredits: nil,
            isAuthenticated: true,
            hasResolvedAccount: true
        ))
        XCTAssertFalse(CodexResetCreditEligibility.isEligible(
            isBlocked: true,
            availableCredits: 1,
            isAuthenticated: false,
            hasResolvedAccount: true
        ))
    }

    /// An unresolvable account (snapshot without a matching stored profile) has
    /// nothing to redeem against. Hide the control rather than offering a button
    /// whose handler silently no-ops.
    func testActionIsIneligibleWithoutAResolvedAccount() {
        XCTAssertFalse(CodexResetCreditEligibility.isEligible(
            isBlocked: true,
            availableCredits: 1,
            isAuthenticated: true,
            hasResolvedAccount: false
        ))
    }

    // MARK: - Confirmation copy

    func testConfirmationNamesTheTargetAccount() {
        let title = CodexResetCreditConfirmation.title(accountName: "Work")
        XCTAssertTrue(title.contains("Work"), "confirmation title must name the account being spent from")
    }

    func testConfirmationMessageNamesAccountAndRemainingCredits() {
        let message = CodexResetCreditConfirmation.message(accountName: "Work", availableCredits: 3)
        XCTAssertTrue(message.contains("Work"), "message must name the target account")
        XCTAssertTrue(message.contains("3"), "message must state the remaining credit count")
        XCTAssertTrue(
            message.lowercased().contains("cannot be undone"),
            "message must state that the spend is irreversible"
        )
    }

    func testConfirmationMessageCallsOutTheFinalCredit() {
        let message = CodexResetCreditConfirmation.message(accountName: "Default CLI Profile", availableCredits: 1)
        XCTAssertTrue(message.contains("Default CLI Profile"))
        XCTAssertTrue(message.lowercased().contains("last reset credit"))
    }

    /// Defensive: a missing or negative count must never render "1 of -1" copy
    /// on a dialog that authorizes an irreversible spend.
    func testConfirmationMessageToleratesMissingCount() {
        let message = CodexResetCreditConfirmation.message(accountName: "Work", availableCredits: nil)
        XCTAssertFalse(message.contains("-"), "unknown counts must not render a negative remainder")
        XCTAssertTrue(message.contains("Work"))
    }

    func testConsumeUsesAvailableCreditAndImmediatelyRefreshesUsage() async throws {
        let session = makeStubSession()
        let service = CodexCliLocalService(
            authFileDataProvider: { self.authFileData() },
            urlSession: session
        )
        var requests: [URLRequest] = []

        StubURLProtocol.handler = { request in
            requests.append(request)
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )

            switch (request.httpMethod, url.path) {
            case ("GET", "/backend-api/wham/rate-limit-reset-credits"):
                return (response, Data(#"{"credits":[{"id":"credit-1","reset_type":"codex_rate_limits","status":"available"}],"available_count":1}"#.utf8))
            case ("POST", "/backend-api/wham/rate-limit-reset-credits/consume"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-1")
                let body = try self.requestBodyData(from: request)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
                XCTAssertEqual(json["credit_id"], "credit-1")
                XCTAssertFalse(try XCTUnwrap(json["redeem_request_id"]).isEmpty)
                return (response, Data(#"{"code":"reset","credit":null,"windows_reset":2}"#.utf8))
            case ("GET", "/backend-api/wham/usage"):
                return (response, Data(#"{"plan_type":"pro","rate_limit":null,"rate_limit_reset_credits":{"available_count":0}}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(url.path)")
                return (response, Data())
            }
        }

        let result = try await service.consumeResetCredit()

        XCTAssertEqual(result.windowsReset, 2)
        XCTAssertEqual(result.refreshedMetrics?.resetCreditsAvailable, 0)
        XCTAssertNil(result.usageRefreshErrorDescription)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET"])
    }

    func testConsumeWithNoAvailableCreditNeverPosts() async {
        let service = CodexCliLocalService(
            authFileDataProvider: { self.authFileData() },
            urlSession: makeStubSession()
        )
        var requestCount = 0
        StubURLProtocol.handler = { request in
            requestCount += 1
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, Data(#"{"credits":[],"available_count":0}"#.utf8))
        }

        do {
            _ = try await service.consumeResetCredit()
            XCTFail("Expected noAvailableCredit")
        } catch let error as CodexResetCreditError {
            XCTAssertEqual(error.localizedDescription, CodexResetCreditError.noAvailableCredit.localizedDescription)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(requestCount, 1)
    }

    func testSuccessfulConsumeReportsRefreshFailureWithoutInvitingRetry() async throws {
        let service = CodexCliLocalService(
            authFileDataProvider: { self.authFileData() },
            urlSession: makeStubSession()
        )
        StubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let statusCode = url.path == "/backend-api/wham/usage" ? 500 : 200
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
            )
            if url.path.hasSuffix("/consume") {
                return (response, Data(#"{"code":"reset","credit":null,"windows_reset":1}"#.utf8))
            }
            if url.path.hasSuffix("rate-limit-reset-credits") {
                return (response, Data(#"{"credits":[{"id":"credit-1","reset_type":"codex_rate_limits","status":"available"}]}"#.utf8))
            }
            return (response, Data())
        }

        let result = try await service.consumeResetCredit()

        XCTAssertEqual(result.windowsReset, 1)
        XCTAssertNil(result.refreshedMetrics)
        XCTAssertEqual(result.usageRefreshErrorDescription, "HTTP 500")
    }

    /// Multi-account targeting: the redemption must read the acted-on card's
    /// `CODEX_HOME` and address the provider with that profile's account id, not
    /// the default profile's.
    func testConsumeTargetsTheAccountWhoseCardActed() async throws {
        let work = CodexAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/codex-work")
        let readAccounts = AccountRecorder()
        let service = CodexCliLocalService(
            accountAuthFileDataProvider: { account in
                readAccounts.record(account.homeDirectory)
                return self.authFileData(accountID: account.isDefault ? "account-default" : "account-work")
            },
            urlSession: makeStubSession()
        )
        var accountHeaders: [String?] = []

        StubURLProtocol.handler = { request in
            accountHeaders.append(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )

            switch (request.httpMethod, url.path) {
            case ("GET", "/backend-api/wham/rate-limit-reset-credits"):
                return (response, Self.availableCreditsBody)
            case ("POST", "/backend-api/wham/rate-limit-reset-credits/consume"):
                return (response, Data(#"{"code":"reset","credit":null,"windows_reset":1}"#.utf8))
            default:
                return (response, Data(#"{"plan_type":"pro","rate_limit":null}"#.utf8))
            }
        }

        _ = try await service.consumeResetCredit(account: work)

        // `nil` is the default profile's (unset) CODEX_HOME, read by the
        // init-time access probe. What matters is that no *other* configured
        // profile's home was consulted for this redemption.
        XCTAssertEqual(Set(readAccounts.homeDirectories.compactMap { $0 }), ["/tmp/codex-work"])
        XCTAssertEqual(Set(accountHeaders.compactMap { $0 }), ["account-work"])
    }

    /// A failed redemption must surface an error and never claim a credit was
    /// spent, so the caller can leave the previously displayed metrics intact.
    func testFailedConsumeThrowsAndSkipsTheUsageRefresh() async {
        let service = CodexCliLocalService(
            authFileDataProvider: { self.authFileData() },
            urlSession: makeStubSession()
        )
        var paths: [String] = []

        StubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            paths.append(url.path)
            let statusCode = request.httpMethod == "POST" ? 500 : 200
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
            )
            if request.httpMethod == "POST" {
                return (response, Data())
            }
            return (response, Self.availableCreditsBody)
        }

        do {
            _ = try await service.consumeResetCredit()
            XCTFail("Expected the failed redemption to throw")
        } catch {
            XCTAssertFalse(
                error.localizedDescription.isEmpty,
                "failure must carry an actionable message for the UI alert"
            )
        }

        XCTAssertFalse(
            paths.contains("/backend-api/wham/usage"),
            "a failed redemption must not refresh usage and overwrite displayed metrics"
        )
    }

    /// `homeDirectory` values seen by the auth-file provider, recorded across the
    /// concurrency boundary the provider closure crosses.
    private final class AccountRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String?] = []

        func record(_ homeDirectory: String?) {
            lock.lock()
            defer { lock.unlock() }
            values.append(homeDirectory)
        }

        var homeDirectories: [String?] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private func makeStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func requestBodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }

        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw try XCTUnwrap(stream.streamError)
            }
            if count == 0 {
                break
            }
            body.append(buffer, count: count)
        }
        return body
    }

    /// One available credit, the shape the GET endpoint returns.
    private static let availableCreditsBody = Data(#"""
    {"credits":[{"id":"credit-1","reset_type":"codex_rate_limits","status":"available"}]}
    """#.utf8)

    private func authFileData(accountID: String = "account-1") -> Data {
        let payload = Data(#"{"exp":4102444800}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Data(#"{"tokens":{"access_token":"header.\#(payload).signature","account_id":"\#(accountID)"}}"#.utf8)
    }
}
