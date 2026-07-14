import ArgumentParser
import Darwin
import Dispatch
import Foundation
import MeterBar

/// Private launchd entry point. Users control it through MeterBar's Session
/// Wake switch; it is intentionally hidden from the normal CLI help surface.
struct WakeAgent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wake-agent",
        abstract: "Run MeterBar's managed Session Wake background agent",
        shouldDisplay: false
    )

    func run() async throws {
        let cancellation = AgentCancellation()
        let signalSources = installSignalHandlers(cancellation)
        defer { signalSources.forEach { $0.cancel() } }

        let exitCode = await SessionWakeAgent.run(shouldCancel: { cancellation.isCancelled })
        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
    }

    private func installSignalHandlers(_ cancellation: AgentCancellation) -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { cancellation.cancel() }
            source.resume()
            return source
        }
    }
}

private final class AgentCancellation: @unchecked Sendable {
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
