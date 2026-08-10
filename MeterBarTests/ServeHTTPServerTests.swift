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
        requestTimeout: TimeInterval = 5,
        dataSource: ServeRouter.DataSource? = nil,
        sourceKey: (@Sendable (Int32) -> String)? = nil
    ) throws -> ServeHTTPServer {
        let server = ServeHTTPServer(configuration: ServeHTTPServer.Configuration(
            host: ServeBindConfiguration.loopbackHost,
            port: 0,
            token: token,
            maxRequestsPerSecond: maxRequestsPerSecond,
            dataSource: dataSource ?? makeDataSource(),
            requestTimeout: requestTimeout,
            sourceKey: sourceKey ?? { ServeHTTPServer.peerAddress(of: $0) }
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

    /// `--allow-remote` puts the listener in front of every device on the LAN.
    /// With one process-wide window charged before auth, any of them could keep
    /// the limiter saturated and hold the token holder at 429 indefinitely, so
    /// the budget an unauthenticated burst can spend must be its own source's.
    func testUnauthenticatedBurstFromOneAddressDoesNotStarveTheTokenHolder() async throws {
        let caller = ScriptedSource(address: "203.0.113.7")
        let server = try startServer(maxRequestsPerSecond: 2, sourceKey: { _ in caller.address })
        defer { server.stop() }

        var burstStatuses: [Int] = []
        for _ in 0..<4 {
            let (response, _) = try await get("/usage", port: server.boundPort, bearerToken: nil)
            burstStatuses.append(response.statusCode)
        }

        caller.address = "127.0.0.1"
        let (legitimate, _) = try await get("/usage", port: server.boundPort, bearerToken: token)

        XCTAssertEqual(
            legitimate.statusCode,
            200,
            "an unauthenticated burst from another address consumed the token holder's budget"
        )
        XCTAssertEqual(Array(burstStatuses.prefix(2)), [401, 401], "got \(burstStatuses)")
        XCTAssertTrue(
            burstStatuses.contains(429),
            "the bursting source was never rate limited, so its pre-auth cost is unbounded: \(burstStatuses)"
        )
    }

    // MARK: Response delivery

    /// `SO_SNDTIMEO` bounds one `write`, not the whole drain: a client that
    /// stops reading part-way through a large `/cost` body makes the next
    /// `write` fail with `EAGAIN`. Giving up there hands the client a truncated
    /// JSON document under a correct `Content-Length` — a silent corruption the
    /// caller can only detect by parsing. The write path must retry against a
    /// deadline the way the read path already does.
    func testServerDeliversTheWholeResponseToAClientThatStallsMidDrain() throws {
        // The write deadline is not what this test is about: give the drain
        // plenty of room so a failure means the loop gave up, not that it ran
        // out of time.
        let server = try startServer(requestTimeout: 20, dataSource: makeLargeCostDataSource())
        defer { server.stop() }

        // A small receive buffer keeps the in-flight window well under the
        // response size, so the server is guaranteed to block mid-body.
        let fd = try connectRawClient(
            port: server.boundPort,
            receiveTimeoutMicroseconds: 500_000,
            receiveBufferBytes: 4_096
        )
        defer { Darwin.close(fd) }

        try sendRaw("GET /cost HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\n\r\n", to: fd)

        // Stall only once bytes are actually arriving. Sleeping straight after
        // the request would spend the stall while the server is still encoding
        // the body, and the drain would then start before any `write` blocked.
        var received = readSome(fd, timeout: 15)
        XCTAssertFalse(received.isEmpty, "the server sent nothing at all")

        // Comfortably longer than *two* of the socket's 1s send timeouts. The
        // first `write` spends one of them and still returns the partial count
        // it managed before the buffer filled; only a whole timeout with zero
        // bytes moved yields the EAGAIN this test is about.
        Thread.sleep(forTimeInterval: 3)

        received.append(contentsOf: drainToEOF(fd, timeout: 15))
        let (head, body) = try splitHTTPMessage(received)

        let contentLength = try XCTUnwrap(
            headerValue(named: "Content-Length", in: head).flatMap(Int.init),
            "response carried no Content-Length"
        )
        XCTAssertEqual(
            body.count,
            contentLength,
            "the response body was truncated after the client stalled (\(body.count) of \(contentLength) bytes)"
        )
        XCTAssertNotNil(
            try? JSONSerialization.jsonObject(with: Data(body)),
            "the delivered body is not parseable JSON"
        )
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

    // MARK: Fixtures

    /// A `/cost` payload far larger than any socket buffer, so one `write` can
    /// never drain it — the shape that exposes a short-write bug.
    private func makeLargeCostDataSource(modelRows: Int = 40_000) -> ServeRouter.DataSource {
        let breakdowns = (0..<modelRows).map { index in
            TokenUsageBreakdown(
                provider: .claudeCode,
                name: "meterbar-large-response-fixture-model-\(index)",
                inputTokens: 1_000,
                outputTokens: 250,
                cacheCreationTokens: 50,
                cacheReadTokens: 500,
                estimatedCostUSD: 1.25,
                sessionCount: 3
            )
        }
        let cache = CostSummaryCache(
            summary: CostSummary(
                costs: [
                    TokenCost(
                        provider: .claudeCode,
                        inputTokens: 1_000,
                        outputTokens: 250,
                        cacheCreationTokens: 50,
                        cacheReadTokens: 500,
                        estimatedCostUSD: 1.25,
                        sessionCount: 3,
                        periodStart: referenceDate.addingTimeInterval(-86_400),
                        periodEnd: referenceDate,
                        modelBreakdowns: breakdowns
                    ),
                ],
                totalCostUSD: 1.25,
                totalTokens: 1_800,
                periodDays: 30
            ),
            lastScanDate: referenceDate
        )
        return ServeRouter.DataSource(loadUsageMetrics: { [:] }, loadCostCache: { cache })
    }

    /// Stands in for `getpeername` so a loopback-only listener can be driven as
    /// if requests arrived from different hosts. The test flips `address`
    /// between phases; connections are keyed with whatever it holds at accept.
    nonisolated private final class ScriptedSource: @unchecked Sendable {
        private let lock = NSLock()
        private var current: String

        init(address: String) { current = address }

        var address: String {
            get {
                lock.lock()
                defer { lock.unlock() }
                return current
            }
            set {
                lock.lock()
                current = newValue
                lock.unlock()
            }
        }
    }

    // MARK: Raw socket helpers

    private func connectRawClient(
        port: UInt16,
        receiveTimeoutMicroseconds: Int32 = 50_000,
        receiveBufferBytes: Int32? = nil
    ) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RawClientError.socketFailed }

        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: receiveTimeoutMicroseconds)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        if var receiveBufferBytes {
            // Must be set before `connect`: the window is negotiated at handshake.
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBufferBytes, socklen_t(MemoryLayout<Int32>.size))
        }

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

    /// Polls until the first bytes arrive, so a test can tell "the server is
    /// mid-response" apart from "the server has not started writing yet".
    private func readSome(_ fd: Int32, timeout: TimeInterval) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count > 0 { return Array(buffer[0..<count]) }
            if count == 0 { return [] }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
            return []
        }
        return []
    }

    /// Reads until the server closes the connection or `timeout` elapses. The
    /// client socket carries a receive timeout, so an empty read is a poll miss,
    /// not end of stream — only `0` means the peer hung up.
    private func drainToEOF(_ fd: Int32, timeout: TimeInterval) -> [UInt8] {
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                received.append(contentsOf: buffer[0..<count])
                continue
            }
            if count == 0 { break }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
            break
        }
        return received
    }

    private func splitHTTPMessage(_ message: [UInt8]) throws -> (head: String, body: [UInt8]) {
        let separator = Array("\r\n\r\n".utf8)
        guard let range = message.firstRange(of: separator) else {
            throw RawClientError.malformedResponse
        }
        let head = try XCTUnwrap(String(bytes: message[..<range.lowerBound], encoding: .utf8))
        return (head, Array(message[range.upperBound...]))
    }

    private func headerValue(named name: String, in head: String) -> String? {
        head
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("\(name.lowercased()):") }
            .map { $0.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces) }
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
        case malformedResponse
    }
}
