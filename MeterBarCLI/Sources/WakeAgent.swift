import ArgumentParser
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
        let cancellation = CLICancellationFlag()
        let signalSources = CLISignalHandlers.install(cancelling: cancellation)
        defer { signalSources.forEach { $0.cancel() } }

        let exitCode = await SessionWakeAgent.run(shouldCancel: { cancellation.isCancelled })
        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
    }
}
