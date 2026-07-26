import Darwin
import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class ServeHTTPServerTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let token = "integration-test-token"

    private func makeDataSource() -> ServeRouter.DataSource {
        let metrics: [ServiceType: UsageMetrics] = [
            .claudeCode: UsageMetrics(
                service: .claudeCode,
                sessionLimit: UsageLimit(used: 10, total: 100, resetTime: nil, windowSeconds: 18_000),
                weeklyLimit: nil,
                extraUsage: nil,
                lastUpdated: referenceDate
            ),
        ]
        return ServeRouter.DataSource(
            loadUsageMetrics: { metrics },
            loadCostCache: { nil }
        )
    }

    private func startServer(
        maxRequestsPerSecond: Int = 100,
        requestTimeout: TimeInterval = 5
    ) throws -> ServeHTTPServer {
        let server = ServeHTTPServer(configuration: ServeHTTPServer.Configuration(
            host: ServeBindConfiguration.loopbackHost,
            port: 0,
            token: token,
            maxRequestsPerSecond: maxRequestsPerSecond,
            dataSource: makeDataSource(),
            requestTimeout: requestTimeout
        ))
        try server.start()
        server.runAcceptLoop()
        return server
    }

    private func get(
        _ path: String,
        port: UInt16,
        bearerToken: String?,
        method: String = "GET"
    ) async throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse), data)
    }

    func testServerBindsToLoopbackAndServesAnAuthenticatedUsageRequest() async throws {
        let server = try startServer()
        defer { server.stop() }

        let (response, data) = try await get("/usage", port: server.boundPort, bearerToken: token)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
    }

    func testServerRejectsMissingTokenWithoutLeakingData() async throws {
        let server = try startServer()
        defer { server.stop() }

        let (response, data) = try await get("/usage", port: server.boundPort, bearerToken: nil)

        XCTAssertEqual(response.statusCode, 401)
        let body = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(body.contains("providers"))
    }

    func testServerRejectsNonGetMethod() async throws {
        let server = try startServer()
        defer { server.stop() }

        let (response, _) = try await get("/usage", port: server.boundPort, bearerToken: token, method: "POST")

        XCTAssertEqual(response.statusCode, 405)
    }

    func testServerRejectsUnknownPath() async throws {
        let server = try startServer()
        defer { server.stop() }

        let (response, _) = try await get("/does-not-exist", port: server.boundPort, bearerToken: token)

        XCTAssertEqual(response.statusCode, 404)
    }

    func testServerEnforcesRateLimit() async throws {
        let server = try startServer(maxRequestsPerSecond: 1)
        defer { server.stop() }

        _ = try await get("/usage", port: server.boundPort, bearerToken: token)
        let (second, _) = try await get("/usage", port: server.boundPort, bearerToken: token)

        XCTAssertEqual(second.statusCode, 429)
    }

    func testStopClosesTheListeningSocketSoNewConnectionsAreRefused() async throws {
        let server = try startServer()
        let port = server.boundPort

        server.stop()
        try await Task.sleep(nanoseconds: 100_000_000)

        do {
            _ = try await get("/usage", port: port, bearerToken: token)
            XCTFail("expected the connection to be refused after stop()")
        } catch {
            // Connection refused (or similar) is expected; the listening socket is gone.
        }
    }

    func testStartingOnAnAlreadyBoundPortFails() throws {
        let first = try startServer()
        defer { first.stop() }

        let second = ServeHTTPServer(configuration: ServeHTTPServer.Configuration(
            host: ServeBindConfiguration.loopbackHost,
            port: first.boundPort,
            token: token,
            maxRequestsPerSecond: 10,
            dataSource: makeDataSource()
        ))

        XCTAssertThrowsError(try second.start())
    }

    // MARK: Connection lifetime

    /// `SO_RCVTIMEO` bounds each individual `recv`, not the connection, so a
    /// client that dribbles one byte just often enough to reset that timer can
    /// otherwise hold a handler thread forever. Only an overall deadline ends
    /// this connection.
    func testServerDropsAClientThatTricklesHeaderBytesWithoutFinishing() throws {
        let server = try startServer(requestTimeout: 1)
        defer { server.stop() }

        let fd = try connectRawClient(port: server.boundPort)
        defer { Darwin.close(fd) }

        // A request line with no terminating blank line — the server can never
        // consider this request complete.
        try sendRaw("GET /usage HTTP/1.1\r\nHost: localhost\r\n", to: fd)

        let start = Date()
        var serverEnded = false
        var buffer = [UInt8](repeating: 0, count: 1_024)
        for _ in 0..<25 {
            _ = try? sendRaw("X", to: fd)
            // The client socket carries a 50ms receive timeout, so this polls
            // rather than blocks; <= 0 means the server answered and hung up,
            // or hung up outright.
            if Darwin.recv(fd, &buffer, buffer.count, 0) > 0 {
                serverEnded = true
                break
            }
            if errno != EAGAIN, errno != EWOULDBLOCK {
                serverEnded = true
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(serverEnded, "the server never ended a trickling connection")
        XCTAssertLessThan(elapsed, 3, "connection outlived its 1s request deadline (took \(elapsed)s)")
    }

    /// A peer that vanishes between the SYN and the `accept` surfaces as a
    /// transient `accept` error. Treating that as fatal would take the whole
    /// listener down with it.
    func testServerKeepsServingAfterConnectionsThatCloseImmediately() async throws {
        let server = try startServer()
        defer { server.stop() }

        for _ in 0..<5 {
            let fd = try connectRawClient(port: server.boundPort)
            Darwin.close(fd)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let (response, _) = try await get("/usage", port: server.boundPort, bearerToken: token)

        XCTAssertEqual(response.statusCode, 200, "the accept loop stopped after abrupt disconnects")
    }

    // MARK: Raw socket helpers

    private func connectRawClient(port: UInt16, receiveTimeoutMicroseconds: Int32 = 50_000) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RawClientError.socketFailed }

        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: receiveTimeoutMicroseconds)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw RawClientError.connectFailed
        }
        return fd
    }

    private func sendRaw(_ text: String, to fd: Int32) throws {
        let bytes = Array(text.utf8)
        let sent = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == bytes.count else { throw RawClientError.sendFailed }
    }

    private enum RawClientError: Error {
        case socketFailed
        case connectFailed
        case sendFailed
    }
}
