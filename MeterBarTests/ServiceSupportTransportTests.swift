import Foundation
@testable import MeterBar
import XCTest

/// Regression for the 1.8.39–1.8.40 launch SIGSEGV: `URLSession.data(for:)`
/// overlay with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` left a nil
/// receiver. Production traffic now uses `ServiceSupport.data` (`dataTask`).
final class ServiceSupportTransportTests: XCTestCase {
    private let definedTransportError = NSError(domain: "ServiceSupportTransportTests", code: 73)

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

    func testDataPropagatesDefinedTransportErrorUnchanged() async {
        let session = makeStubSession { _ in
            throw self.definedTransportError
        }
        defer { StubURLProtocol.handler = nil }

        let request = URLRequest(url: URL(string: "https://example.com/transport-error")!)
        do {
            _ = try await ServiceSupport.data(for: request, session: session)
            XCTFail("the transport error must propagate")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, definedTransportError.domain)
            XCTAssertEqual(nsError.code, definedTransportError.code)
        }
    }

    func testDataCancellationCancelsInFlightTaskAndReturnsCancelledPromptly() async throws {
        let started = expectation(description: "transport started")
        let stopped = expectation(description: "transport stopped")
        let session = makeStubSession { request in
            started.fulfill()
            Thread.sleep(forTimeInterval: 0.5)
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, Data("too late".utf8))
        }
        StubURLProtocol.onStop = {
            stopped.fulfill()
        }
        defer {
            StubURLProtocol.handler = nil
            StubURLProtocol.onStop = nil
        }

        let request = URLRequest(url: URL(string: "https://example.com/pending")!)
        let task = Task {
            try await ServiceSupport.data(for: request, session: session)
        }
        await fulfillment(of: [started], timeout: 1)

        let cancellationStart = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelling the caller must cancel the transport")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(cancellationStart), 0.25)
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testDataAlreadyCancelledBeforeTaskInstallationReturnsCancelled() async {
        let session = makeStubSession(statusCode: 200, body: "too late")
        defer { StubURLProtocol.handler = nil }

        let request = URLRequest(url: URL(string: "https://example.com/pre-cancelled")!)
        let task = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            return try await ServiceSupport.data(for: request, session: session)
        }

        do {
            _ = try await task.value
            XCTFail("a pre-cancelled caller must not receive a transport result")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testDataCancellationCompletionRaceSettlesExactlyOnce() async throws {
        let session = makeStubSession(statusCode: 200, body: "ok")
        defer { StubURLProtocol.handler = nil }
        let request = URLRequest(url: URL(string: "https://example.com/race")!)

        for _ in 0..<100 {
            let task = Task {
                try await ServiceSupport.data(for: request, session: session)
            }
            let cancellationTask = Task {
                await Task.yield()
                task.cancel()
            }

            do {
                let (data, response) = try await task.value
                XCTAssertEqual(data, Data("ok".utf8))
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            } catch let error as URLError {
                XCTAssertEqual(error.code, .cancelled)
            } catch {
                XCTFail("unexpected error type: \(error)")
            }
            await cancellationTask.value
        }
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
        makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
            )
            return (response, Data(body.utf8))
        }
    }

    private func makeStubSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.handler = handler
        return URLSession(configuration: configuration)
    }

    private final class StubURLProtocol: URLProtocol {
        static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        static var onStop: (() -> Void)?

        override static func canInit(with request: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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

        override func stopLoading() {
            Self.onStop?()
        }
    }
}
