import Darwin
import Foundation

nonisolated public enum ServeHTTPServerError: Error, Sendable {
    case invalidHost(String)
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}

/// Minimal HTTP/1.1, GET-only listener over a raw BSD socket. `meterbar serve`
/// needs one bounded, read-only endpoint rather than a general-purpose
/// server, and the brief asks to keep the dependency footprint minimal
/// (docs/cli-json-schema.md) — a raw socket also gives explicit, verifiable
/// control over the loopback-vs-all-interfaces bind address, which
/// `Network.framework`'s listener APIs do not expose as directly.
///
/// `@unchecked Sendable`: all mutable state (the listening fd and the running
/// flag) is guarded by `stateLock`; everything else is immutable.
nonisolated public final class ServeHTTPServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public let host: String
        public let port: UInt16
        public let token: String
        public let maxRequestsPerSecond: Int
        public let dataSource: ServeRouter.DataSource
        public let requestTimeout: TimeInterval

        public init(
            host: String,
            port: UInt16,
            token: String,
            maxRequestsPerSecond: Int,
            dataSource: ServeRouter.DataSource,
            requestTimeout: TimeInterval = ServeHTTPServer.defaultRequestTimeout
        ) {
            self.host = host
            self.port = port
            self.token = token
            self.maxRequestsPerSecond = maxRequestsPerSecond
            self.dataSource = dataSource
            self.requestTimeout = requestTimeout
        }
    }

    /// Wall-clock bound on how long one connection may take to deliver a
    /// complete request head. Configurable only so tests can drive it down;
    /// nothing on the CLI surface exposes it.
    public static let defaultRequestTimeout: TimeInterval = 5

    /// How long a single `recv`/`write` may block. Deliberately shorter than
    /// the request deadline: `SO_RCVTIMEO` restarts on every byte received, so
    /// it can't bound a connection on its own — it only needs to wake the read
    /// loop often enough to notice the deadline has passed.
    private static let socketPollSeconds: Int = 1
    private static let maxRequestBytes = 8_192
    private static let listenBacklog: Int32 = 16

    private let configuration: Configuration
    private let rateLimiter: ServeRateLimiter
    private let stateLock = NSLock()
    private var listenSocket: Int32 = -1

    public private(set) var boundPort: UInt16 = 0

    public init(configuration: Configuration) {
        self.configuration = configuration
        rateLimiter = ServeRateLimiter(maxPerSecond: configuration.maxRequestsPerSecond)
    }

    /// Creates, binds, and starts listening. Does not accept connections yet
    /// — call `runAcceptLoop()` to start serving.
    public func start() throws {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = configuration.port.bigEndian
        let ptonResult = configuration.host.withCString { hostPointer in
            inet_pton(AF_INET, hostPointer, &addr.sin_addr)
        }
        guard ptonResult == 1 else {
            throw ServeHTTPServerError.invalidHost(configuration.host)
        }

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServeHTTPServerError.socketCreationFailed(errno) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        let bindResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ServeHTTPServerError.bindFailed(code)
        }

        guard Darwin.listen(fd, Self.listenBacklog) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ServeHTTPServerError.listenFailed(code)
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }

        stateLock.lock()
        listenSocket = fd
        boundPort = UInt16(bigEndian: actual.sin_port)
        stateLock.unlock()
    }

    /// Runs the accept loop on a dedicated background queue so the caller
    /// (an async CLI command) never parks a cooperative thread on a blocking
    /// syscall. Each connection is handled on a concurrent queue so one slow
    /// client can't stall new accepts.
    public func runAcceptLoop() {
        let acceptQueue = DispatchQueue(label: "dev.meterbar.serve.accept")
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    /// Closes the listening socket, which unblocks the accept loop's blocking
    /// `accept()` call with an error so it exits immediately.
    public func stop() {
        stateLock.lock()
        let fd = listenSocket
        listenSocket = -1
        stateLock.unlock()
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    private func acceptLoop() {
        while true {
            stateLock.lock()
            let fd = listenSocket
            stateLock.unlock()
            guard fd >= 0 else { return }

            let clientFD = Darwin.accept(fd, nil, nil)
            if clientFD < 0 {
                guard Self.isTransientAcceptError(errno) else { return }
                // stop() closing the listening socket lands in the `return`
                // above (EBADF); everything here is a peer or a signal
                // misbehaving on one connection, which must not take the
                // listener down with it.
                if errno == EMFILE || errno == ENFILE {
                    // Descriptor exhaustion clears only when an in-flight
                    // handler closes, so back off instead of spinning hot.
                    usleep(100_000)
                }
                continue
            }

            configureTimeouts(clientFD)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handle(connection: clientFD)
            }
        }
    }

    /// `accept` failures a live listener recovers from: a signal arriving
    /// mid-call, a peer that disconnected between the SYN and the accept, a
    /// spurious wakeup, or transient descriptor exhaustion.
    private static func isTransientAcceptError(_ code: Int32) -> Bool {
        code == EINTR || code == ECONNABORTED || code == EAGAIN
            || code == EWOULDBLOCK || code == EMFILE || code == ENFILE
    }

    private func configureTimeouts(_ fd: Int32) {
        var timeout = timeval(tv_sec: Self.socketPollSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func handle(connection fd: Int32) {
        defer { Darwin.close(fd) }

        guard rateLimiter.allow() else {
            write(response: ServeRouter.tooManyRequestsResponse(), to: fd)
            return
        }

        let deadline = Date().addingTimeInterval(configuration.requestTimeout)
        guard let request = Self.readRequest(from: fd, deadline: deadline) else {
            write(response: ServeRouter.malformedRequestResponse(), to: fd)
            return
        }

        let response = ServeRouter.handle(request, token: configuration.token, dataSource: configuration.dataSource)
        write(response: response, to: fd)
    }

    private func write(response: ServeHTTPResponse, to fd: Int32) {
        let data = Self.serialize(response)
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var remaining = buffer.count
            var pointer = buffer.baseAddress
            while remaining > 0, let base = pointer {
                let written = Darwin.write(fd, base, remaining)
                guard written > 0 else { return }
                remaining -= written
                pointer = base + written
            }
        }
    }

    // MARK: Parsing

    /// Bounded by `deadline` rather than by the socket's own receive timeout:
    /// `SO_RCVTIMEO` restarts on every byte that arrives, so a client sending
    /// one byte just inside that window could otherwise hold a handler thread
    /// open indefinitely.
    private static func readRequest(from fd: Int32, deadline: Date) -> ServeHTTPRequest? {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 1_024)
        while buffer.count < maxRequestBytes {
            guard Date() < deadline else { return nil }

            let bytesRead = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if bytesRead > 0 {
                buffer.append(contentsOf: chunk[0..<bytesRead])
                if let terminatorIndex = headerTerminatorIndex(in: buffer) {
                    return parse(headerBytes: Array(buffer[..<terminatorIndex]))
                }
                continue
            }

            // 0 means the peer closed; there is no more request coming. -1 with
            // EAGAIN/EWOULDBLOCK is just this recv hitting `socketPollSeconds`,
            // so loop back and re-check the deadline instead of giving up.
            guard bytesRead < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else { return nil }
        }
        return nil
    }

    private static func headerTerminatorIndex(in buffer: [UInt8]) -> Int? {
        let terminator: [UInt8] = [13, 10, 13, 10] // \r\n\r\n
        guard buffer.count >= terminator.count else { return nil }
        let lastIndex = buffer.count - terminator.count
        for index in 0...lastIndex where Array(buffer[index..<(index + terminator.count)]) == terminator {
            return index
        }
        return nil
    }

    private static func parse(headerBytes: [UInt8]) -> ServeHTTPRequest? {
        guard let text = String(bytes: headerBytes, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        let (path, query) = splitTarget(String(parts[1]))

        var authorizationHeader: String?
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare("Authorization") == .orderedSame else { continue }
            authorizationHeader = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
        }

        return ServeHTTPRequest(
            method: String(parts[0]),
            path: path,
            query: query,
            authorizationHeader: authorizationHeader
        )
    }

    private static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        guard let queryIndex = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[target.startIndex..<queryIndex])
        var query: [String: String] = [:]
        for pair in target[target.index(after: queryIndex)...].split(separator: "&") {
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = keyValue.first else { continue }
            let key = rawKey.removingPercentEncoding ?? String(rawKey)
            let value = keyValue.count > 1 ? (String(keyValue[1]).removingPercentEncoding ?? String(keyValue[1])) : ""
            query[key] = value
        }
        return (path, query)
    }

    private static func serialize(_ response: ServeHTTPResponse) -> Data {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"

        var head = "HTTP/1.1 \(response.status) \(statusText(response.status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(response.body)
        return data
    }

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 429: return "Too Many Requests"
        default: return "Internal Server Error"
        }
    }
}
