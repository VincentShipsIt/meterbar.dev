import ArgumentParser
import Darwin
import Dispatch
import Foundation
import MeterBar

/// Trigger one bounded provider refresh through MeterBar's coordinator.
struct Refresh: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Refresh provider usage now and report what changed"
    )

    @Flag(name: .shortAndLong, help: "Emit only the versioned JSON response on stdout.")
    var json: Bool = false

    @Option(name: .shortAndLong, help: "Seconds to wait before giving up on the refresh.")
    var timeout: Double = UsageRefreshCLI.defaultTimeout

    func validate() throws {
        guard timeout >= UsageRefreshCLI.minimumTimeout, timeout <= UsageRefreshCLI.maximumTimeout else {
            throw ValidationError(
                "--timeout must be between \(Int(UsageRefreshCLI.minimumTimeout)) "
                    + "and \(Int(UsageRefreshCLI.maximumTimeout)) seconds."
            )
        }
    }

    func run() async throws {
        let cancelBox = RefreshCancelBox()
        let signalSource = installSignalHandler(cancelBox)
        defer { signalSource.cancel() }

        let result = await UsageRefreshCLI.run(
            UsageRefreshCLI.Request(timeout: timeout, shouldCancel: { cancelBox.isCancelled })
        )
        emit(result)
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

    private func installSignalHandler(_ box: RefreshCancelBox) -> DispatchSourceSignal {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { box.cancel() }
        source.resume()
        return source
    }
}

private final class RefreshCancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

private struct RefreshStandardError: TextOutputStream {
    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
