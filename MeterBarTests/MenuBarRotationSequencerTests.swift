import MeterBarShared
import XCTest

@testable import MeterBar

/// Covers the pure rotation decision behind the merged status item: which
/// providers take part, in what order, and when a pin, a critical quota, or an
/// open popover takes the wheel instead (issue #340).
final class MenuBarRotationSequencerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func candidate(
        key: String,
        service: ServiceType = .claudeCode,
        percentUsed: Double,
        updatedMinutesAgo: Double = 0,
        isAutoSelectable: Bool = true
    ) -> StatusLimitCandidate {
        StatusLimitCandidate(
            key: key,
            pinKey: key,
            service: service,
            displayName: key,
            windowName: "Session",
            limit: UsageLimit(used: percentUsed, total: 100, resetTime: nil),
            lastUpdated: now.addingTimeInterval(-updatedMinutesAgo * 60),
            lastActivity: nil,
            isAutoSelectable: isAutoSelectable
        )
    }

    private func outcome(
        _ candidates: [StatusLimitCandidate],
        tick: Int,
        pinnedKey: String? = nil
    ) -> MenuBarRotationOutcome {
        MenuBarRotationSequencer.outcome(
            candidates: candidates,
            tick: tick,
            pinnedKey: pinnedKey,
            now: now
        )
    }

    private func rotatedKey(_ candidates: [StatusLimitCandidate], tick: Int) -> String? {
        guard case let .rotate(candidate) = outcome(candidates, tick: tick) else { return nil }
        return candidate.key
    }

    // MARK: - Scheduling

    func testRotationOnlyRunsWhenEnabledInMergedModeWithoutAPin() {
        XCTAssertTrue(MenuBarRotationSequencer.rotates(mode: .merged, isEnabled: true, pinnedKey: nil))
        XCTAssertFalse(MenuBarRotationSequencer.rotates(mode: .merged, isEnabled: false, pinnedKey: nil))
        // A pin is a deliberate choice of one window, so it wins outright.
        XCTAssertFalse(MenuBarRotationSequencer.rotates(mode: .merged, isEnabled: true, pinnedKey: "codex"))
        for mode in MenuBarPresentationMode.allCases where mode != .merged {
            XCTAssertFalse(
                MenuBarRotationSequencer.rotates(mode: mode, isEnabled: true, pinnedKey: nil),
                "\(mode) owns its own items and must not rotate"
            )
        }
    }

    // MARK: - Ordering

    func testRotationVisitsEveryProviderInAStableOrderAndWraps() {
        let claude = candidate(key: "claude", percentUsed: 40)
        let codex = candidate(key: "codex", service: .codexCli, percentUsed: 30)
        let cursor = candidate(key: "cursor", service: .cursor, percentUsed: 20)
        // Deliberately unsorted: the order must come from the sequencer, not
        // from however the probes happened to emit the candidates.
        let candidates = [cursor, claude, codex]

        let visited = (0..<5).map { rotatedKey(candidates, tick: $0) }

        XCTAssertEqual(visited, ["claude", "codex", "cursor", "claude", "codex"])
    }

    func testRotationSkipsProvidersWithoutData() {
        let fresh = candidate(key: "claude", percentUsed: 40)
        let stale = candidate(key: "codex", service: .codexCli, percentUsed: 30, updatedMinutesAgo: 180)
        let pinOnly = candidate(key: "cursor", service: .cursor, percentUsed: 20, isAutoSelectable: false)

        let rotatable = MenuBarRotationSequencer.rotatableCandidates([fresh, stale, pinOnly], now: now)

        XCTAssertEqual(rotatable.map(\.key), ["claude"])
        XCTAssertEqual(rotatedKey([fresh, stale, pinOnly], tick: 1), "claude")
    }

    func testRotationStandsDownWhenNoProviderHasData() {
        let stale = candidate(key: "claude", percentUsed: 40, updatedMinutesAgo: 180)

        XCTAssertEqual(outcome([stale], tick: 0), .inactive)
        XCTAssertEqual(outcome([], tick: 0), .inactive)
    }

    // MARK: - Pin exclusion

    func testAPinnedWindowTakesTheSlotInsteadOfRotating() {
        let claude = candidate(key: "claude", percentUsed: 40)
        let codex = candidate(key: "codex", service: .codexCli, percentUsed: 30)

        XCTAssertEqual(outcome([claude, codex], tick: 1, pinnedKey: "codex"), .inactive)
    }

    // MARK: - Critical hold

    func testACriticalQuotaHoldsTheSlotUntilItClears() {
        let claude = candidate(key: "claude", percentUsed: 40)
        let critical = candidate(key: "codex", service: .codexCli, percentUsed: 94)

        // Held on every tick, not just the one that would have shown it.
        XCTAssertEqual(outcome([claude, critical], tick: 0), .hold(critical))
        XCTAssertEqual(outcome([claude, critical], tick: 1), .hold(critical))

        let recovered = candidate(key: "codex", service: .codexCli, percentUsed: 50)
        XCTAssertEqual(outcome([claude, recovered], tick: 1), .rotate(recovered))
    }

    func testASpentQuotaAutoSelectionSkipsDoesNotFreezeRotation() {
        // Auto-selection drops fully spent quotas so the title can't sit on 0%
        // for days. Rotation moves on by itself, so the spent provider keeps its
        // turn instead of holding the slot forever.
        let claude = candidate(key: "claude", percentUsed: 20)
        let spent = candidate(key: "codex", service: .codexCli, percentUsed: 100)

        XCTAssertEqual(rotatedKey([claude, spent], tick: 0), "claude")
        XCTAssertEqual(rotatedKey([claude, spent], tick: 1), "codex")
    }

    func testEverythingSpentHoldsTheSlotLikeAutoSelectionWould() {
        let claude = candidate(key: "claude", percentUsed: 100)
        let codex = candidate(key: "codex", service: .codexCli, percentUsed: 100)

        XCTAssertEqual(outcome([claude, codex], tick: 1), .hold(claude))
    }

    // MARK: - Pause / resume

    func testPausingHoldsTheTickSoTheLabelCannotChangeUnderTheCursor() {
        XCTAssertEqual(MenuBarRotationSequencer.advance(tick: 3, isPaused: true), 3)
        XCTAssertEqual(MenuBarRotationSequencer.advance(tick: 3, isPaused: false), 4)
    }

    func testTickAdvanceWrapsInsteadOfOverflowing() {
        XCTAssertEqual(MenuBarRotationSequencer.advance(tick: .max, isPaused: false), 0)
    }

    func testNegativeTicksStillResolveToARealProvider() {
        let claude = candidate(key: "claude", percentUsed: 40)
        let codex = candidate(key: "codex", service: .codexCli, percentUsed: 30)

        XCTAssertEqual(rotatedKey([claude, codex], tick: -1), "codex")
    }
}
