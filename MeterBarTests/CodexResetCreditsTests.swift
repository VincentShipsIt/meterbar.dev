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
            isAuthenticated: true
        ))
        XCTAssertFalse(CodexResetCreditEligibility.isEligible(
            isBlocked: false,
            availableCredits: 1,
            isAuthenticated: true
        ))
        XCTAssertFalse(CodexResetCreditEligibility.isEligible(
            isBlocked: true,
            availableCredits: 0,
            isAuthenticated: true
        ))
        XCTAssertFalse(CodexResetCreditEligibility.isEligible(
            isBlocked: true,
            availableCredits: nil,
            isAuthenticated: true
        ))
        XCTAssertFalse(CodexResetCreditEligibility.isEligible(
            isBlocked: true,
            availableCredits: 1,
            isAuthenticated: false
        ))
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

    private func authFileData() -> Data {
        let payload = Data(#"{"exp":4102444800}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Data(#"{"tokens":{"access_token":"header.\#(payload).signature","account_id":"account-1"}}"#.utf8)
    }
}
