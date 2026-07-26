import Foundation

/// Orchestrates one `meterbar serve` run: start the listener, report where it
/// bound, wait for a cancellation signal, then shut down. Kept separate from
/// `ServeHTTPServer` so the CLI's signal-handling glue (`Serve.swift`) has a
/// single async entry point to await, and so it's testable without spawning
/// a real process or touching SIGINT/SIGTERM.
nonisolated public enum ServeCLI {
    public struct Request: Sendable {
        public let host: String
        public let port: UInt16
        public let token: String
        public let maxRequestsPerSecond: Int

        public init(host: String, port: UInt16, token: String, maxRequestsPerSecond: Int) {
            self.host = host
            self.port = port
            self.token = token
            self.maxRequestsPerSecond = maxRequestsPerSecond
        }
    }

    public struct StartupInfo: Sendable, Equatable {
        public let host: String
        public let port: UInt16
    }

    public enum Outcome: Sendable, Equatable {
        case stopped
        case failedToStart(message: String)
    }

    /// How often to poll `shouldCancel` while the server is running. Short
    /// enough that `meterbar serve` reacts to a signal promptly, long enough
    /// not to busy-loop.
    private static let pollInterval: UInt64 = 50_000_000 // 50ms

    public static func run(
        _ request: Request,
        dataSource: ServeRouter.DataSource,
        onReady: @Sendable (StartupInfo) -> Void = { _ in },
        shouldCancel: @Sendable () -> Bool
    ) async -> Outcome {
        // Fail before binding rather than exposing an endpoint whose auth
        // check can never reject anything.
        guard ServeToken.isUsable(request.token) else {
            return .failedToStart(message: "The bearer token must not be blank.")
        }

        let server = ServeHTTPServer(configuration: ServeHTTPServer.Configuration(
            host: request.host,
            port: request.port,
            token: request.token,
            maxRequestsPerSecond: request.maxRequestsPerSecond,
            dataSource: dataSource
        ))

        do {
            try server.start()
        } catch {
            return .failedToStart(message: String(describing: error))
        }

        server.runAcceptLoop()
        onReady(StartupInfo(host: request.host, port: server.boundPort))

        while !shouldCancel() {
            try? await Task.sleep(nanoseconds: pollInterval)
        }

        server.stop()
        return .stopped
    }
}
