import ArgumentParser
import Foundation
import MeterBar

// MARK: - Route

/// Recommend a provider, account, and model tier for a kind of work.
struct Route: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "route",
        abstract: "Recommend which provider, account, and model tier to use for a task",
        discussion: """
        Recommendation only: route reads the usage MeterBar has cached and
        prints where the work should go and why. It never starts a process,
        switches a credential, or reads a prompt.

        Exit codes are a scripting contract (see docs/cli-json-schema.md):
        0 route recommended, 11 every candidate rejected, 12 no usable or
        fresh quota data, 13 usage error.

        Pass --refresh to run one bounded refresh first.
        """
    )

    @Option(
        name: .shortAndLong,
        help: ArgumentHelp(
            "Kind of work: planning, implementation, debugging, review, research, quick-edit, custom, "
                + "or a task you defined."
        )
    )
    var task: String?

    @Flag(name: .shortAndLong, help: "Emit only the versioned JSON response on stdout.")
    var json = false

    @Flag(name: .long, help: "Refresh usage before deciding instead of reading the cached snapshot.")
    var refresh = false

    /// Text, not Double, for the same reason as `guard`: a malformed value must
    /// exit with the documented usage code, not ArgumentParser's generic one.
    @Option(name: .long, help: "Seconds to allow for --refresh before falling back to the cache.")
    var refreshTimeout: String?

    func run() async throws {
        // `--refresh` can hold the process for minutes; see Guard.run().
        let cancellation = CLICancellationFlag()
        let signalSources = CLISignalHandlers.install(cancelling: cancellation)
        defer { signalSources.forEach { $0.cancel() } }

        let result = await WorkloadRouteCLI.run(
            WorkloadRouteCLI.Request(
                task: task,
                refresh: refresh,
                refreshTimeout: refreshTimeout,
                shouldCancel: { cancellation.isCancelled }
            )
        )
        emit(result)
        throw ExitCode(result.exitCode)
    }

    private func emit(_ result: WorkloadRouteCLI.Result) {
        if json {
            print(result.jsonOutput)
            return
        }
        print(result.headline)
        if result.exitCode == 0 {
            result.details.forEach { print($0) }
        } else {
            var stderr = RouteStandardError()
            result.details.forEach { Swift.print($0, to: &stderr) }
        }
    }
}

// MARK: - RouteStandardError

private struct RouteStandardError: TextOutputStream {
    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else {
            return
        }
        FileHandle.standardError.write(data)
    }
}
