import XCTest
@testable import MeterBar

final class PublicProfileClientTests: XCTestCase {
    private final class StubURLProtocol: URLProtocol {
        static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        static var requests: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.append(request)
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

    private let base = URL(string: "https://meterbar.test")!
    private let slug = "abcdefghjk"

    override func setUp() {
        super.setUp()
        StubURLProtocol.requests = []
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func client() -> PublicProfileClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return PublicProfileClient(baseURL: base, configuration: configuration)
    }

    private func respond(_ status: Int) {
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
        }
    }

    private var document: PublicProfileDocument {
        PublicProfileDocument(schema: 1, updatedAt: Date(timeIntervalSince1970: 1_800_000_000), providers: [], receipt: nil)
    }

    func testPublishPutsTheDocumentWithTheKeyAsBearer() async throws {
        respond(204)

        let result = await client().publish(document, slug: slug, publishKey: "secret-key")

        XCTAssertEqual(result, .ok)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://meterbar.test/api/profile/abcdefghjk")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    /// The key must never be in the URL, where a proxy log or the site's own
    /// access log would keep it.
    func testKeyTravelsInTheHeaderNeverTheURL() async {
        respond(204)

        _ = await client().publish(document, slug: slug, publishKey: "secret-key")
        _ = await client().delete(slug: slug, publishKey: "secret-key")

        for request in StubURLProtocol.requests {
            XCTAssertFalse(request.url?.absoluteString.contains("secret-key") ?? true)
        }
    }

    func testDeleteTreatsAlreadyGoneAsDeleted() async {
        respond(404)
        let result = await client().delete(slug: slug, publishKey: "k")
        XCTAssertEqual(result, .ok)
    }

    func testPublishDoesNotTreatMissingAsSuccess() async {
        respond(404)
        let result = await client().publish(document, slug: slug, publishKey: "k")
        XCTAssertEqual(result, .failed("meterbar.dev answered HTTP 404."))
    }

    func testRefusedKeyIsRejectedNotRetryable() async {
        for status in [401, 403, 409] {
            respond(status)
            let result = await client().publish(document, slug: slug, publishKey: "k")
            XCTAssertEqual(result, .rejected, "HTTP \(status)")
        }
    }

    func testServerErrorAndTransportFailureAreRetryableFailures() async {
        respond(503)
        let server = await client().delete(slug: slug, publishKey: "k")
        XCTAssertEqual(server, .failed("meterbar.dev answered HTTP 503."))

        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let offline = await client().delete(slug: slug, publishKey: "k")
        XCTAssertEqual(offline, .failed("Could not reach meterbar.dev."))
    }

    /// The delegate refuses redirects (the bearer key must not follow one), so a
    /// 3xx reaches the caller as an error rather than being chased.
    func testARedirectResponseIsAFailureNotASuccess() async {
        respond(307)
        let result = await client().publish(document, slug: slug, publishKey: "k")
        XCTAssertEqual(result, .failed("meterbar.dev answered HTTP 307."))
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }
}
