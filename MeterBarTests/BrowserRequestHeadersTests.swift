import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Locks the browser-spoof header contract that provider dashboard APIs check.
///
/// Cursor and Codex both reject plain API clients, so every request has to look
/// like it came from the provider's own web dashboard. Those header blocks used
/// to be hand-written at three call sites; these tests pin both the shared
/// builder and the values each service actually puts on the wire, so a future
/// edit to one site can't silently drift from the others.
final class BrowserRequestHeadersTests: XCTestCase {
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

    // MARK: - Shared builder

    func testBrowserHeadersCarryTheSiteIdentityAndSharedUserAgent() {
        let headers = ServiceSupport.browserHeaders(for: .chatGPT)

        XCTAssertEqual(headers["Origin"], "https://chatgpt.com")
        XCTAssertEqual(headers["Referer"], "https://chatgpt.com/")
        XCTAssertEqual(headers["User-Agent"], ServiceSupport.browserUserAgent)
    }

    func testBrowserHeadersDefaultToJSONAndAcceptAnOverride() {
        XCTAssertEqual(ServiceSupport.browserHeaders(for: .chatGPT)["Accept"], "application/json")
        XCTAssertEqual(ServiceSupport.browserHeaders(for: .chatGPT, accept: "*/*")["Accept"], "*/*")
    }

    /// Origin and Referer are validated together by the provider, so they live
    /// in one value. These are the exact strings the hand-written blocks used.
    func testKnownSitesKeepTheirExactOriginRefererPairs() {
        XCTAssertEqual(ServiceSupport.BrowserSite.chatGPT.origin, "https://chatgpt.com")
        XCTAssertEqual(ServiceSupport.BrowserSite.chatGPT.referer, "https://chatgpt.com/")
        XCTAssertEqual(ServiceSupport.BrowserSite.cursorDashboard.origin, "https://cursor.com")
        XCTAssertEqual(
            ServiceSupport.BrowserSite.cursorDashboard.referer,
            "https://cursor.com/dashboard?tab=usage"
        )
    }

    func testApplyBrowserHeadersWritesEveryFieldOntoTheRequestAndSetsTheTimeout() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://chatgpt.com/backend-api/wham/usage")))
        ServiceSupport.applyBrowserHeaders(to: &request, for: .chatGPT, accept: "*/*")

        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://chatgpt.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://chatgpt.com/")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "*/*")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), ServiceSupport.browserUserAgent)
        XCTAssertEqual(request.timeoutInterval, ServiceSupport.usageRequestTimeout)
    }

    /// Applying twice must not append duplicate values — `setValue` replaces,
    /// `addValue` would comma-join and break the Origin check.
    func testApplyBrowserHeadersReplacesRatherThanAppends() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://cursor.com/api")))
        ServiceSupport.applyBrowserHeaders(to: &request, for: .chatGPT, accept: "*/*")
        ServiceSupport.applyBrowserHeaders(to: &request, for: .cursorDashboard)

        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://cursor.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    // MARK: - Codex requests on the wire

    func testCodexUsageRequestSendsBrowserHeadersWithWildcardAccept() async throws {
        let service = CodexCliLocalService(
            authFileDataProvider: { self.codexAuthFileData() },
            urlSession: makeStubSession()
        )
        var seen: URLRequest?
        StubURLProtocol.handler = { request in
            seen = request
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let payload = #"{"plan_type":"pro","rate_limit":null,"rate_limit_reset_credits":{"available_count":0}}"#
            return (response, Data(payload.utf8))
        }

        _ = try await service.fetchUsageMetrics()

        let request = try XCTUnwrap(seen)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://chatgpt.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://chatgpt.com/")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "*/*")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), ServiceSupport.browserUserAgent)
        // Auth is unchanged by the header refactor and must still ride along.
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-1")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    /// The reset-credit lookup keeps the JSON default. Consuming throws
    /// `noAvailableCredit` on the empty payload, which is fine — the GET this
    /// asserts on has already gone out by then.
    func testCodexResetCreditLookupSendsBrowserHeadersWithJSONAccept() async throws {
        let service = CodexCliLocalService(
            authFileDataProvider: { self.codexAuthFileData() },
            urlSession: makeStubSession()
        )
        var seen: URLRequest?
        StubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path.hasSuffix("rate-limit-reset-credits") { seen = request }
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, Data(#"{"credits":[],"available_count":0}"#.utf8))
        }

        _ = try? await service.consumeResetCredit()

        let request = try XCTUnwrap(seen)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://chatgpt.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://chatgpt.com/")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), ServiceSupport.browserUserAgent)
    }

    // MARK: - Cursor headers

    /// Cursor layers its session cookie and a JSON content type on top of the
    /// shared browser identity; the shared fields must match the builder exactly.
    func testCursorHeadersExtendTheSharedBrowserSetWithAuth() {
        let headers = CursorLocalService.dashboardHeaders(userId: "user-1", token: "token-1")
        let shared = ServiceSupport.browserHeaders(for: .cursorDashboard, accept: "*/*")

        for (field, value) in shared {
            XCTAssertEqual(headers[field], value, "Cursor drifted from the shared browser headers on \(field)")
        }
        XCTAssertEqual(headers["Content-Type"], "application/json")
        XCTAssertEqual(headers["Cookie"], "WorkosCursorSessionToken=user-1%3A%3Atoken-1")
    }

    // MARK: - Helpers

    private func makeStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func codexAuthFileData() -> Data {
        let payload = Data(#"{"exp":4102444800}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Data(#"{"tokens":{"access_token":"header.\#(payload).signature","account_id":"account-1"}}"#.utf8)
    }
}
