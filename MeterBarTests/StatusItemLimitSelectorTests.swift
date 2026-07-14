import XCTest
@testable import MeterBar
import MeterBarShared

final class StatusItemLimitSelectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func candidate(
        key: String,
        percentUsed: Double,
        activeMinutesAgo: Double? = nil,
        displayName: String? = nil,
        pinKey: String? = nil,
        windowName: String = "Session",
        isAutoSelectable: Bool = true
    ) -> StatusLimitCandidate {
        StatusLimitCandidate(
            key: key,
            pinKey: pinKey ?? key,
            displayName: displayName ?? key,
            windowName: windowName,
            limit: UsageLimit(used: percentUsed, total: 100, resetTime: nil),
            lastActivity: activeMinutesAgo.map { now.addingTimeInterval(-$0 * 60) },
            isAutoSelectable: isAutoSelectable
        )
    }

    private func select(
        _ candidates: [StatusLimitCandidate],
        previousKey: String? = nil,
        pinnedKey: String? = nil
    ) -> StatusLimitCandidate? {
        StatusItemLimitSelector.select(
            candidates: candidates,
            previousKey: previousKey,
            pinnedKey: pinnedKey,
            now: now
        )
    }

    // MARK: - Basics

    func testEmptyCandidatesReturnsNil() {
        XCTAssertNil(select([]))
    }

    func testSingleCandidateIsSelectedEvenWhenIdle() {
        let only = candidate(key: "codex", percentUsed: 20, activeMinutesAgo: nil)
        XCTAssertEqual(select([only])?.key, "codex")
    }

    // MARK: - Active-account filtering

    func testTightestAmongActiveWinsOverTighterIdleAccount() {
        // The idle account is far tighter (10% left) but hasn't been used;
        // the menu bar should follow the accounts actually in use.
        let idleTight = candidate(key: "claude:old", percentUsed: 90, activeMinutesAgo: nil)
        let activeLoose = candidate(key: "claude:ship", percentUsed: 40, activeMinutesAgo: 5)
        XCTAssertEqual(select([idleTight, activeLoose])?.key, "claude:ship")
    }

    func testStaleActivityBeyondWindowCountsAsIdle() {
        let stale = candidate(key: "claude:old", percentUsed: 90, activeMinutesAgo: 31)
        let active = candidate(key: "codex", percentUsed: 40, activeMinutesAgo: 5)
        XCTAssertEqual(select([stale, active])?.key, "codex")
    }

    func testActivityExactlyAtWindowBoundaryCountsAsActive() {
        let boundary = candidate(key: "claude:ship", percentUsed: 90, activeMinutesAgo: 30)
        let active = candidate(key: "codex", percentUsed: 40, activeMinutesAgo: 5)
        XCTAssertEqual(select([boundary, active])?.key, "claude:ship")
    }

    func testFallsBackToTightestOverallWhenNothingIsActive() {
        // Preserves the pre-feature behavior when no account shows recent use.
        let loose = candidate(key: "codex", percentUsed: 20, activeMinutesAgo: nil)
        let tight = candidate(key: "claude:ship", percentUsed: 80, activeMinutesAgo: 120)
        XCTAssertEqual(select([loose, tight])?.key, "claude:ship")
    }

    // MARK: - Sticky selection (hysteresis)

    func testKeepsPreviousActiveAccountWithinHysteresis() {
        // codex is tighter by 4 points — inside the 5-point band, so no flip.
        let claude = candidate(key: "claude:ship", percentUsed: 60, activeMinutesAgo: 2)
        let codex = candidate(key: "codex", percentUsed: 64, activeMinutesAgo: 1)
        XCTAssertEqual(select([claude, codex], previousKey: "claude:ship")?.key, "claude:ship")
    }

    func testKeepsPreviousAtExactHysteresisBoundary() {
        let claude = candidate(key: "claude:ship", percentUsed: 60, activeMinutesAgo: 2)
        let codex = candidate(key: "codex", percentUsed: 65, activeMinutesAgo: 1)
        XCTAssertEqual(select([claude, codex], previousKey: "claude:ship")?.key, "claude:ship")
    }

    func testSwitchesWhenPreviousIsClearlyLooserThanTightestActive() {
        let claude = candidate(key: "claude:ship", percentUsed: 60, activeMinutesAgo: 2)
        let codex = candidate(key: "codex", percentUsed: 70, activeMinutesAgo: 1)
        XCTAssertEqual(select([claude, codex], previousKey: "claude:ship")?.key, "codex")
    }

    func testSwitchesAwayFromPreviousWhenItGoesIdle() {
        let claude = candidate(key: "claude:ship", percentUsed: 90, activeMinutesAgo: nil)
        let codex = candidate(key: "codex", percentUsed: 40, activeMinutesAgo: 1)
        XCTAssertEqual(select([claude, codex], previousKey: "claude:ship")?.key, "codex")
    }

    func testStickyAlsoAppliesToIdleFallbackPool() {
        // Nothing active: pool is "all", and the previously shown account stays
        // put while within the hysteresis band.
        let claude = candidate(key: "claude:ship", percentUsed: 60, activeMinutesAgo: nil)
        let codex = candidate(key: "codex", percentUsed: 63, activeMinutesAgo: nil)
        XCTAssertEqual(select([claude, codex], previousKey: "claude:ship")?.key, "claude:ship")
    }

    func testUnknownPreviousKeyFallsBackToTightest() {
        let claude = candidate(key: "claude:ship", percentUsed: 60, activeMinutesAgo: 2)
        let codex = candidate(key: "codex", percentUsed: 80, activeMinutesAgo: 1)
        XCTAssertEqual(select([claude, codex], previousKey: "cursor")?.key, "codex")
    }

    // MARK: - Determinism

    func testEqualPercentagesTieBreakByKeyForStableOutput() {
        let a = candidate(key: "claude:a", percentUsed: 50, activeMinutesAgo: 1)
        let b = candidate(key: "claude:b", percentUsed: 50, activeMinutesAgo: 1)
        XCTAssertEqual(select([b, a])?.key, "claude:a")
        XCTAssertEqual(select([a, b])?.key, "claude:a")
    }

    func testCodexAccountsCompeteIndependentlyByActivity() {
        let idle = candidate(key: "codex:personal", percentUsed: 95)
        let active = candidate(key: "codex:work", percentUsed: 45, activeMinutesAgo: 2)

        XCTAssertEqual(select([idle, active])?.key, "codex:work")
    }

    // MARK: - Pinned selection

    func testPinnedWindowWinsOverAutoHeuristic() {
        let automatic = candidate(key: "codex:work:session", percentUsed: 90, activeMinutesAgo: 1)
        let pinned = candidate(
            key: "claude:personal:weekly",
            percentUsed: 20,
            windowName: "Weekly",
            isAutoSelectable: false
        )

        XCTAssertEqual(
            select([automatic, pinned], pinnedKey: pinned.key)?.key,
            pinned.key
        )
    }

    func testPinnedAutoWindowMatchesPersistentPinKeyWithoutChangingLegacyAutoKey() {
        let claude = candidate(key: "claude:work", percentUsed: 90, activeMinutesAgo: 1)
        let codex = candidate(
            key: "codex:work",
            percentUsed: 20,
            activeMinutesAgo: 1,
            pinKey: "codexCli:account-id:session"
        )

        let selection = select([claude, codex], pinnedKey: "codexCli:account-id:session")

        XCTAssertEqual(selection?.key, "codex:work")
        XCTAssertEqual(selection?.pinKey, "codexCli:account-id:session")
    }

    func testUnavailablePinFallsBackToByteCompatibleAutoSelection() {
        let claude = candidate(key: "claude:work:session", percentUsed: 40, activeMinutesAgo: 2)
        let codex = candidate(key: "codex:work:session", percentUsed: 70, activeMinutesAgo: 1)

        XCTAssertEqual(
            select([claude, codex], pinnedKey: "cursor:default:weekly")?.key,
            "codex:work:session"
        )
    }

    func testPinOnlyWindowsDoNotChangeAutoSelection() {
        let session = candidate(key: "codex:work:session", percentUsed: 40, activeMinutesAgo: 1)
        let weekly = candidate(
            key: "codex:work:weekly",
            percentUsed: 95,
            activeMinutesAgo: 1,
            windowName: "Weekly",
            isAutoSelectable: false
        )

        XCTAssertEqual(select([session, weekly])?.key, session.key)
    }
}
