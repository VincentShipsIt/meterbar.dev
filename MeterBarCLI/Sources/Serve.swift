import ArgumentParser
import Darwin
import Dispatch
import Foundation
import MeterBar

/// `meterbar serve` — a local, token-gated, read-only HTTP view of the same
/// cached usage/cost data `meterbar usage --json` / `cost --json` emit. Never
/// triggers a provider refresh and never mutates state (docs/cli-json-schema.md).
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Serve usage and cost data over a local, token-gated, read-only HTTP endpoint"
    )

    static let defaultPort: UInt16 = 47_663
    static let defaultMaxRequestsPerSecond = 5

    @Option(help: "Port to listen on.")
    var port: UInt16 = Serve.defaultPort

    @Option(help: "Bearer token required on every request. If omitted, one is generated and printed once.")
    var token: String?

    @Flag(help: "Bind to all network interfaces instead of loopback only. Exposes usage/cost data to other devices.")
    var allowRemote: Bool = false

    @Option(help: "Maximum requests served per second before responding 429 Too Many Requests.")
    var maxRequestsPerSecond: Int = Serve.defaultMaxRequestsPerSecond

    func validate() throws {
        if maxRequestsPerSecond < 1 {
            throw ValidationError("--max-requests-per-second must be 1 or greater.")
        }
    }

    func run() async throws {
        let generatedToken = token == nil
        let resolvedToken = token ?? ServeToken.generate()
        let bind = ServeBindConfiguration.resolve(allowRemote: allowRemote)

        if let warning = bind.warning {
            FileHandle.standardError.write(Data("⚠ \(warning)\n".utf8))
        }

        let cancellation = ServeCancellation()
        let signalSources = installSignalHandlers(cancellation)
        defer { signalSources.forEach { $0.cancel() } }

        let request = ServeCLI.Request(
            host: bind.host,
            port: port,
            token: resolvedToken,
            maxRequestsPerSecond: maxRequestsPerSecond
        )

        let outcome = await ServeCLI.run(
            request,
            dataSource: .liveCache,
            onReady: { info in
                print("meterbar serve listening on http://\(info.host):\(info.port)")
                print("Endpoints: GET /usage, GET /cost (Authorization: Bearer <token> required)")
                if generatedToken {
                    // Printed exactly once, at startup, and never logged again —
                    // this is the only place the token is ever surfaced.
                    print("Bearer token (generated, shown once): \(resolvedToken)")
                }
                print("Press Ctrl-C to stop.")
            },
            shouldCancel: { cancellation.isCancelled }
        )

        switch outcome {
        case .stopped:
            return
        case .failedToStart(let message):
            throw ValidationError("Failed to start meterbar serve: \(message)")
        }
    }

    private func installSignalHandlers(_ cancellation: ServeCancellation) -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { cancellation.cancel() }
            source.resume()
            return source
        }
    }
}

private final class ServeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
