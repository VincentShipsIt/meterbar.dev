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

    /// The detached hop must actually leave the main actor when awaited from a
    /// main-actor caller — every provider refresh enters the network this way,
    /// and a hop that silently stayed on main is the setup for the launch
    /// SIGSEGVs (#480, #488, #490).
    @MainActor
    func testDetachedRunsOperationOffMainThreadAndReturnsValue() async throws {
        nonisolated final class ThreadRecorder: @unchecked Sendable {
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
        let value = try await ServiceSupport.detached {
            recorder.record()
            return 7
        }

        XCTAssertEqual(value, 7)
        XCTAssertTrue(recorder.wasCalled)
        XCTAssertFalse(recorder.wasCalledOnMainThread, "detached work must not run as a main-actor job")
    }

    @MainActor
    func testDetachedPropagatesOperationErrors() async {
        do {
            _ = try await ServiceSupport.detached { () -> Int in
                throw ServiceError.apiError("HTTP 500")
            }
            XCTFail("the operation's error must propagate to the caller")
        } catch let ServiceError.apiError(message) {
            XCTAssertEqual(message, "HTTP 500")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    @MainActor
    func testFetchValidatedDataReturnsBodyForSuccessResponses() async throws {
        let session = makeStubSession(statusCode: 200, body: "ok")
        defer { StubURLProtocol.handler = nil }

        let request = URLRequest(url: URL(string: "https://example.com/ok")!)
        // The exact production composition: detached hop wrapping fetch+validate.
        let data = try await ServiceSupport.detached {
            try await ServiceSupport.fetchValidatedData(request, session: session)
        }

        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
    }

    @MainActor
    func testFetchValidatedDataMaps401ToNotAuthenticated() async {
        let session = makeStubSession(statusCode: 401, body: #"{"error":"bad key"}"#)
        defer { StubURLProtocol.handler = nil }

        let request = URLRequest(url: URL(string: "https://example.com/auth")!)
        do {
            _ = try await ServiceSupport.fetchValidatedData(request, session: session)
            XCTFail("a 401 must throw notAuthenticated")
        } catch ServiceError.notAuthenticated {
            // expected
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// Provider bodies can contain account data — the error must carry the
    /// status code only, never the response body.
    @MainActor
    func testFetchValidatedDataKeepsOnlyStatusCodeForServerErrors() async {
        let session = makeStubSession(statusCode: 500, body: "secret account detail")
        defer { StubURLProtocol.handler = nil }

        let request = URLRequest(url: URL(string: "https://example.com/fail")!)
        do {
            _ = try await ServiceSupport.fetchValidatedData(request, session: session)
            XCTFail("a 500 must throw apiError")
        } catch let ServiceError.apiError(message) {
            XCTAssertEqual(message, "HTTP 500", "the error must carry the status code only")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    private func makeStubSession(statusCode: Int, body: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
            )
            return (response, Data(body.utf8))
        }
        return URLSession(configuration: configuration)
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
