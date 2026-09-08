import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Covers issue #531: `applicationWillTerminate` must force pending
/// `UserDefaults` writes out before the process can exit, because a real
/// relaunch reads from disk and an abrupt teardown never guarantees the
/// debounced write-back ran. `TerminationPreferencesFlush` is the extracted,
/// testable seam `AppDelegate.applicationWillTerminate` calls into — mirroring
/// how `PowerAssertionManager.shutdown()` and `GrokAgentProcess.terminateAll()`
/// are themselves independently testable rather than exercised through
/// `AppDelegate` directly.
final class TerminationPreferencesFlushTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeSuite() throws -> UserDefaults {
        let name = "TerminationPreferencesFlushTests.\(UUID().uuidString)"
        suiteNames.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    func testFlushInvokesTheInjectedBarrierForEveryConfiguredSuite() throws {
        let standard = try makeSuite()
        let appGroup = try makeSuite()
        var flushed: [UserDefaults] = []
        let flush = TerminationPreferencesFlush(
            suites: [standard, appGroup],
            persistenceBarrier: { defaults in
                flushed.append(defaults)
                return true
            }
        )

        flush.flush()

        XCTAssertEqual(flushed.count, 2)
        XCTAssertTrue(flushed.contains(where: { $0 === standard }))
        XCTAssertTrue(flushed.contains(where: { $0 === appGroup }))
    }

    /// The default barrier is real `synchronize()` — same default as
    /// `credentialPersistenceBarrier` on `ClaudeCodeAccountStore` /
    /// `CodexAccountStore` — so production callers get a real flush without
    /// having to supply one.
    func testDefaultBarrierIsSynchronize() throws {
        let suite = try makeSuite()
        suite.set("value", forKey: "TerminationPreferencesFlushTests.key")
        let flush = TerminationPreferencesFlush(suites: [suite])

        XCTAssertTrue(flush.persistenceBarrier(suite))
    }

    /// The default suite list always includes the standard domain: every
    /// menu-bar and account preference key lives there.
    func testDefaultSuitesIncludesStandardUserDefaults() {
        let flush = TerminationPreferencesFlush()

        XCTAssertTrue(flush.suites.contains { $0 === UserDefaults.standard })
    }

    /// The app-group suite (`group.dev.meterbar.app`) holds real preference
    /// writes of its own — `SessionWakeSettingsStore.syncSharedWakeTarget` and
    /// `syncSharedFeatureFlag` write there for the bundled CLI to read — so the
    /// default suite list must cover it too whenever the app-group container is
    /// resolvable. `UserDefaults(suiteName:)` hands back a fresh object on every
    /// call (not a cached singleton like `.standard`), so identity comparison
    /// can't confirm this — round-trip a probe value through the same domain
    /// name instead.
    func testDefaultSuitesIncludesTheAppGroupSuiteWhenResolvable() throws {
        let flush = TerminationPreferencesFlush()
        let key = "TerminationPreferencesFlushTests.appGroupProbe.\(UUID().uuidString)"
        let appGroup = try XCTUnwrap(UserDefaults(suiteName: SharedMetricsStore.appGroupIdentifier))
        defer { appGroup.removeObject(forKey: key) }

        let nonStandardSuite = try XCTUnwrap(flush.suites.first { $0 !== UserDefaults.standard })
        nonStandardSuite.set(true, forKey: key)

        XCTAssertTrue(appGroup.bool(forKey: key))
    }

    func testFlushToleratesAnEmptySuiteListWithoutCrashing() {
        var callCount = 0
        let flush = TerminationPreferencesFlush(suites: [], persistenceBarrier: { _ in
            callCount += 1
            return true
        })

        flush.flush()

        XCTAssertEqual(callCount, 0)
    }
}
