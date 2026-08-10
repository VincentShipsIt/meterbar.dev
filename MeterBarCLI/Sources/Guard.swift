import ArgumentParser
import Darwin
import Dispatch
import Foundation
import MeterBar

/// Answer "may I spend quota right now?" with a stable exit code.
struct Guard: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guard",
        abstract: "Check whether a provider quota window is safe to spend",
        discussion: """
            Exit codes are a scripting contract (see docs/cli-json-schema.md):
            0 available, 10 below --min-remaining, 11 exhausted,
            12 no usable or fresh snapshot, 13 usage error.

            Reads the cached snapshot MeterBar maintains. Pass --refresh to run
            one bounded refresh first. guard never waits for a quota to reset
            and never consumes reset credits — that is `meterbar wake`.
            """
    )

    @Flag(name: .shortAndLong, help: "Emit only the versioned JSON response on stdout.")
    var json: Bool = false

    @Option(name: .shortAndLong, help: "Provider to check (claude, codex, cursor, openrouter, grok).")
    var provider: String = QuotaGuardCLI.defaultProvider

    @Option(name: .shortAndLong, help: "Quota window to check (session, weekly, code-review).")
    var limit: String = QuotaGuardCLI.defaultWindow

    // Taken as text, not Double, so a malformed threshold exits with the
    // documented usage code instead of ArgumentParser's generic one.
    @Option(
        name: .long,
        help: "Minimum percent of quota that must remain. Default: anything short of exhausted passes."
    )
    var minRemaining: String?

    @Option(name: .long, help: "Check one configured account by its config directory.")
    var configDir: String?

    @Flag(name: .long, help: "Refresh usage before deciding instead of reading the cached snapshot.")
    var refresh: Bool = false

    // Text for the same reason as --min-remaining: typed as Double, a
    // non-numeric value dies inside ArgumentParser's own conversion with
    // EX_USAGE and no JSON document, never reaching the documented exit 13.
    @Option(name: .long, help: "Seconds to allow for --refresh before falling back to the cache.")
    var refreshTimeout: String?

    func run() async throws {
        let cancellation = GuardCancellation()
        let signalSources = installSignalHandlers(cancellation)
        defer { signalSources.forEach { $0.cancel() } }

        let result = await QuotaGuardCLI.run(
            QuotaGuardCLI.Request(
                provider: provider,
                window: limit,
                minRemaining: minRemaining,
                configDirectory: configDir,
                refresh: refresh,
                refreshTimeout: refreshTimeout,
                shouldCancel: { cancellation.isCancelled }
            )
        )
        emit(result)
        throw ExitCode(result.exitCode)
    }

    /// `--refresh` can hold the process for up to ten minutes. Without these,
    /// Ctrl-C or a `timeout(1)` wrapper killed guard mid-window with no JSON
    /// and an exit code outside the documented set. Cancelling ends the refresh
    /// early; guard still evaluates the cached snapshot and exits 0/10/11/12/13
    /// — consistent with a refresh that simply failed.
    private func installSignalHandlers(_ cancellation: GuardCancellation) -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { cancellation.cancel() }
            source.resume()
            return source
        }
    }

    private func emit(_ result: QuotaGuardCLI.Result) {
        if json {
            print(result.jsonOutput)
            return
        }
        print(result.summaryLine)
        if let message = result.message {
            var stderr = GuardStandardError()
            Swift.print(message, to: &stderr)
        }
    }
}

private final class GuardCancellation: @unchecked Sendable {
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

private struct GuardStandardError: TextOutputStream {
    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
