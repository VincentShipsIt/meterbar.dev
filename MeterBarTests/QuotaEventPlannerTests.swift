import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class QuotaEventPlannerTests: XCTestCase {
    private let account = QuotaEventAccount(id: "default", name: "Default")
    private let workAccount = QuotaEventAccount(
        id: "45B5BB1D-2994-44B5-9374-54760DCBE901",
        name: "Work"
    )
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testEmitsWarningCriticalExhaustedAndRecoveredTransitions() {
        var planner = QuotaEventPlanner(debounceInterval: 60)

        XCTAssertTrue(planner.evaluate(
            snapshots: [snapshot(account: account, used: 50)],
            now: start
        ).isEmpty, "The first observation primes state instead of firing from cached launch data.")

        let warning = planner.evaluate(
            snapshots: [snapshot(account: account, used: 76)],
            now: start.addingTimeInterval(1)
        )
        let critical = planner.evaluate(
            snapshots: [snapshot(account: account, used: 91)],
            now: start.addingTimeInterval(2)
        )
        let exhausted = planner.evaluate(
            snapshots: [snapshot(account: account, used: 100)],
            now: start.addingTimeInterval(3)
        )
        let recovered = planner.evaluate(
            snapshots: [snapshot(account: account, used: 0)],
            now: start.addingTimeInterval(4)
        )

        XCTAssertEqual(warning.map(\.event), [.warning])
        XCTAssertEqual(critical.map(\.event), [.critical])
        XCTAssertEqual(exhausted.map(\.event), [.exhausted])
        XCTAssertEqual(recovered.map(\.event), [.recovered])
        XCTAssertEqual(exhausted.first?.provider, .cursor)
        XCTAssertEqual(exhausted.first?.account, account)
        XCTAssertEqual(exhausted.first?.window, .session)
        XCTAssertEqual(exhausted.first?.percentage, 100)
        XCTAssertEqual(exhausted.first?.band, .exhausted)
        XCTAssertEqual(exhausted.first?.timestamp, start.addingTimeInterval(3))
    }

    func testRepeatedAndFlappingStatesAreDeduplicatedUntilRearmedOutsideDebounce() {
        var planner = QuotaEventPlanner(debounceInterval: 60)
        _ = planner.evaluate(snapshots: [snapshot(account: account, used: 50)], now: start)

        let first = planner.evaluate(
            snapshots: [snapshot(account: account, used: 76)],
            now: start.addingTimeInterval(1)
        )
        let repeated = planner.evaluate(
            snapshots: [snapshot(account: account, used: 80)],
            now: start.addingTimeInterval(2)
        )
        _ = planner.evaluate(
            snapshots: [snapshot(account: account, used: 50)],
            now: start.addingTimeInterval(3)
        )
        let flap = planner.evaluate(
            snapshots: [snapshot(account: account, used: 76)],
            now: start.addingTimeInterval(4)
        )
        _ = planner.evaluate(
            snapshots: [snapshot(account: account, used: 50)],
            now: start.addingTimeInterval(61)
        )
        let rearmed = planner.evaluate(
            snapshots: [snapshot(account: account, used: 76)],
            now: start.addingTimeInterval(62)
        )

        XCTAssertEqual(first.map(\.event), [.warning])
        XCTAssertTrue(repeated.isEmpty)
        XCTAssertTrue(flap.filter { $0.event == .warning }.isEmpty)
        XCTAssertEqual(rearmed.map(\.event), [.warning])
    }

    func testTracksEachProviderAccountAndWindowIndependently() {
        var planner = QuotaEventPlanner(debounceInterval: 60)
        let personal = snapshot(account: account, used: 50)
        let work = snapshot(account: workAccount, used: 50)
        _ = planner.evaluate(snapshots: [personal, work], now: start)

        let events = planner.evaluate(
            snapshots: [
                snapshot(account: account, used: 50),
                snapshot(account: workAccount, used: 76),
            ],
            now: start.addingTimeInterval(1)
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.account, workAccount)
        XCTAssertEqual(events.first?.event, .warning)
    }

    func testGrokProfilesEmitWarningCriticalExhaustedAndRecoveredIndependentlyPerWindow() {
        var planner = QuotaEventPlanner(debounceInterval: 60)
        let personal = QuotaEventAccount(id: GrokAccount.defaultID.uuidString, name: "Personal")
        let work = QuotaEventAccount(
            id: "C3D4E5F6-A7B8-4901-8234-567890ABCDEF",
            name: "Work"
        )
        _ = planner.evaluate(
            snapshots: [
                grokSnapshot(account: personal, sessionUsed: 50, weeklyUsed: 50),
                grokSnapshot(account: work, sessionUsed: 50, weeklyUsed: 50),
            ],
            now: start
        )

        let warning = planner.evaluate(
            snapshots: [
                grokSnapshot(account: personal, sessionUsed: 76, weeklyUsed: 50),
                grokSnapshot(account: work, sessionUsed: 50, weeklyUsed: 50),
            ],
            now: start.addingTimeInterval(1)
        )
        let critical = planner.evaluate(
            snapshots: [
                grokSnapshot(account: personal, sessionUsed: 76, weeklyUsed: 50),
                grokSnapshot(account: work, sessionUsed: 50, weeklyUsed: 91),
            ],
            now: start.addingTimeInterval(2)
        )
        let exhausted = planner.evaluate(
            snapshots: [
                grokSnapshot(account: personal, sessionUsed: 100, weeklyUsed: 50),
                grokSnapshot(account: work, sessionUsed: 50, weeklyUsed: 91),
            ],
            now: start.addingTimeInterval(3)
        )
        let recovered = planner.evaluate(
            snapshots: [
                grokSnapshot(account: personal, sessionUsed: 0, weeklyUsed: 50),
                grokSnapshot(account: work, sessionUsed: 50, weeklyUsed: 91),
            ],
            now: start.addingTimeInterval(4)
        )

        XCTAssertEqual(warning.map(\.account), [personal])
        XCTAssertEqual(warning.map(\.event), [.warning])
        XCTAssertEqual(warning.map(\.window), [.session])
        XCTAssertEqual(critical.map(\.account), [work])
        XCTAssertEqual(critical.map(\.event), [.critical])
        XCTAssertEqual(critical.map(\.window), [.weekly])
        XCTAssertEqual(exhausted.map(\.account), [personal])
        XCTAssertEqual(exhausted.map(\.event), [.exhausted])
        XCTAssertEqual(exhausted.map(\.window), [.session])
        XCTAssertEqual(recovered.map(\.account), [personal])
        XCTAssertEqual(recovered.map(\.event), [.recovered])
        XCTAssertEqual(recovered.map(\.window), [.session])
    }

    func testLegacyGrokDefaultNamespaceReprimesToTheAccountIdWithoutReplaying() {
        var planner = QuotaEventPlanner(debounceInterval: 60)
        let legacy = QuotaEventAccount(id: "default", name: "Grok")
        let migrated = QuotaEventAccount(id: GrokAccount.defaultID.uuidString, name: GrokAccount.defaultName)
        _ = planner.evaluate(
            snapshots: [grokSnapshot(account: legacy, sessionUsed: 91, weeklyUsed: 50)],
            now: start
        )

        let afterMigration = planner.evaluate(
            snapshots: [grokSnapshot(account: migrated, sessionUsed: 91, weeklyUsed: 50)],
            now: start.addingTimeInterval(1)
        )
        let exhausted = planner.evaluate(
            snapshots: [grokSnapshot(account: migrated, sessionUsed: 100, weeklyUsed: 50)],
            now: start.addingTimeInterval(2)
        )

        XCTAssertTrue(afterMigration.isEmpty)
        XCTAssertEqual(exhausted.map(\.event), [.exhausted])
        XCTAssertEqual(exhausted.first?.account, migrated)
    }

    func testRemovedAccountNamespaceReprimesInsteadOfReplayingAStaleCrossing() {
        var planner = QuotaEventPlanner(debounceInterval: 60)
        _ = planner.evaluate(
            snapshots: [snapshot(account: workAccount, used: 50)],
            now: start
        )
        _ = planner.evaluate(snapshots: [], now: start.addingTimeInterval(1))

        let readdedAlreadyCritical = planner.evaluate(
            snapshots: [snapshot(account: workAccount, used: 91)],
            now: start.addingTimeInterval(2)
        )
        let exhausted = planner.evaluate(
            snapshots: [snapshot(account: workAccount, used: 100)],
            now: start.addingTimeInterval(3)
        )

        XCTAssertTrue(readdedAlreadyCritical.isEmpty)
        XCTAssertEqual(exhausted.map(\.event), [.exhausted])
    }

    private func snapshot(
        account: QuotaEventAccount,
        used: Double
    ) -> QuotaEventSnapshot {
        QuotaEventSnapshot(
            provider: .cursor,
            account: account,
            metrics: UsageMetrics(
                service: .cursor,
                sessionLimit: UsageLimit(
                    used: used,
                    total: 100,
                    resetTime: start.addingTimeInterval(3_600)
                ),
                lastUpdated: start
            )
        )
    }

    private func grokSnapshot(
        account: QuotaEventAccount,
        sessionUsed: Double,
        weeklyUsed: Double
    ) -> QuotaEventSnapshot {
        QuotaEventSnapshot(
            provider: .grok,
            account: account,
            metrics: UsageMetrics(
                service: .grok,
                sessionLimit: UsageLimit(
                    used: sessionUsed,
                    total: 100,
                    resetTime: start.addingTimeInterval(3_600)
                ),
                weeklyLimit: UsageLimit(
                    used: weeklyUsed,
                    total: 100,
                    resetTime: start.addingTimeInterval(86_400)
                ),
                lastUpdated: start
            )
        )
    }
}
