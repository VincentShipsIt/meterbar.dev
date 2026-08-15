import ArgumentParser
import Foundation
import MeterBar

/// Trigger one bounded provider refresh through MeterBar's coordinator.
struct Refresh: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Refresh provider usage now and report what changed"
    )

    @Flag(name: .shortAndLong, help: "Emit only the versioned JSON response on stdout.")
    var json: Bool = false

    // Taken as text, not Double: ArgumentParser's own conversion runs before
    // validate() and before run(), so a malformed value would exit EX_USAGE
    // with no JSON document — neither the code nor the output the refresh
    // contract promises. `meterbar guard` takes its thresholds as text for the
    // same reason.
    @Option(name: .shortAndLong, help: "Seconds to wait before giving up on the refresh.")
    var timeout: String?

    func run() async throws {
        // SIGTERM as well as SIGINT: a refresh started by a script or a timeout
        // wrapper is far more likely to be terminated than interrupted, and
        // both must still produce the documented JSON and exit code.
        let cancelBox = CLICancellationFlag()
        let signalSources = CLISignalHandlers.install(cancelling: cancelBox)
        defer { signalSources.forEach { $0.cancel() } }

        let result = await UsageRefreshCLI.run(
            UsageRefreshCLI.Request(timeoutText: timeout, shouldCancel: { cancelBox.isCancelled })
        )
        emit(result)
        // The response is already out; wait — bounded — for an over-running
        // refresh to release the cross-process lock rather than leaving it to
        // process teardown.
        await result.awaitPendingCleanup()
        throw ExitCode(result.exitCode)
    }

    private func emit(_ result: UsageRefreshCLI.Result) {
        if json {
            print(result.jsonOutput)
            return
        }
        print(result.summaryLine)
        if let message = result.message {
            var stderr = RefreshStandardError()
            Swift.print(message, to: &stderr)
        }
    }
}

private struct RefreshStandardError: TextOutputStream {
    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
