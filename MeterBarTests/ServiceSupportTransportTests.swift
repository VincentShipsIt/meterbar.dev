import Foundation
@testable import MeterBar
import XCTest

/// Regression for the 1.8.39–1.8.40 launch SIGSEGV: `URLSession.data(for:)`
/// overlay with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` left a nil
/// receiver. Production traffic now uses `ServiceSupport.data` (`dataTask`).
final class ServiceSupportTransportTests: XCTestCase {
    func testDataFromMainActorDoesNotCrashEnteringURLSessionOverlay() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        StubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, "example.com")
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, Data("ok".utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let request = URLRequest(url: URL(string: "https://example.com/ok")!)
        let (data, response) = try await ServiceSupport.data(for: request, session: session)

        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

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
}
