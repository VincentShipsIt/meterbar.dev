import Foundation
import MeterBarShared

/// Flushes pending `UserDefaults` writes on the normal quit path.
///
/// `UserDefaults` debounces its write-back to disk. `applicationWillTerminate`
/// already treats abrupt-teardown risk as real for two other resources —
/// `PowerAssertionManager.shared.shutdown()` releases the IOKit assertion and
/// `GrokAgentProcess.terminateAll()` reaps subprocesses — but never forced the
/// in-memory preference writes out before the process could die. MeterBar is a
/// long-lived menu-bar app that Sparkle replaces routinely, so that gap is not
/// theoretical.
///
/// This mirrors the credential stores' `credentialPersistenceBarrier`
/// (`CredentialLocationStore.swift`, `ClaudeCodeAccount.swift`,
/// `CodexAccount.swift`): an injectable closure defaulting to `synchronize()`,
/// so a test can assert the flush happens for every durable suite without
/// depending on real disk timing.
final class TerminationPreferencesFlush {
    static let shared = TerminationPreferencesFlush()

    /// The suites this app durably writes preferences into. `.standard` holds
    /// every menu-bar, account, and feature preference key. The app-group
    /// suite additionally holds real writes of its own — `SessionWakeSettingsStore`
    /// mirrors the active wake target and the feature kill-switch there for the
    /// bundled `meterbar wake` CLI to read — so it is not just a read-only cache
    /// mirror and is worth flushing too.
    let suites: [UserDefaults]
    let persistenceBarrier: (UserDefaults) -> Bool

    init(
        suites: [UserDefaults] = TerminationPreferencesFlush.defaultSuites(),
        persistenceBarrier: ((UserDefaults) -> Bool)? = nil
    ) {
        self.suites = suites
        self.persistenceBarrier = persistenceBarrier ?? { $0.synchronize() }
    }

    /// Called from `applicationWillTerminate` on the normal quit path only.
    /// Forces every durable suite's pending writes out so a process that ends
    /// abruptly right after this point cannot lose a preference write that
    /// already happened in memory.
    func flush() {
        for suite in suites {
            _ = persistenceBarrier(suite)
        }
    }

    private static func defaultSuites() -> [UserDefaults] {
        var suites = [UserDefaults.standard]
        if let appGroup = UserDefaults(suiteName: SharedMetricsStore.appGroupIdentifier) {
            suites.append(appGroup)
        }
        return suites
    }
}
