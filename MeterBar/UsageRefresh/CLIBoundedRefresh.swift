import Foundation

/// One bounded refresh for CLI commands that read the cache afterwards.
///
/// `meterbar guard --refresh` and `meterbar route --refresh` both refresh
/// through the coordinator the app and `meterbar refresh` share, so neither can
/// start a second concurrent poll, and both must leave the cross-process lock
/// released before they evaluate and exit.
enum CLIBoundedRefresh {
    @MainActor
    static func run(
        timeout: TimeInterval,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async {
        let result = await UsageRefreshCLI.run(
            UsageRefreshCLI.Request(timeout: timeout, shouldCancel: shouldCancel)
        )
        // The command keeps running after the refresh, so it must not leave the
        // lock held by an abandoned task while it evaluates and exits.
        await result.awaitPendingCleanup()
    }
}
