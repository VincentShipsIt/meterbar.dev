import Foundation
import MeterBarShared

/// What rotation wants the merged status item to show for the current tick.
nonisolated enum MenuBarRotationOutcome: Equatable {
    /// Rotation owns the slot and this provider has the turn.
    case rotate(StatusLimitCandidate)
    /// A critical or exhausted quota outranks rotation, so the existing
    /// auto-selection keeps the slot until the condition clears.
    case hold(StatusLimitCandidate)
    /// Rotation does not apply: a pin owns the slot, or no provider has data.
    /// The caller must fall back to its normal selection.
    case inactive
}

/// Opt-in timed rotation for the merged status item (issue #340).
///
/// Pure by design: the visible candidate set plus a tick index fully determine
/// what shows, so ordering, skips, pauses, and the critical hold are all
/// testable without a run loop. The timer that advances the tick lives in the
/// controller layer, which is also the only place that knows the popover is
/// open.
nonisolated enum MenuBarRotationSequencer {
    /// Whether a rotation timer should exist at all. Rotation is a merged-mode
    /// feature, and a pin is a deliberate choice of one window that outranks it,
    /// so both cases tear the timer down rather than letting it tick unseen.
    static func rotates(
        mode: MenuBarPresentationMode,
        isEnabled: Bool,
        pinnedKey: String?
    ) -> Bool {
        isEnabled && mode == .merged && pinnedKey == nil
    }

    /// The providers that take a turn: the same auto-selectable windows the
    /// merged item already competes over, minus the ones whose cached data has
    /// aged out — rotating onto a "—" would be a turn that says nothing.
    /// Providers the user hid never reach the candidate list in the first place.
    ///
    /// Sorted like the per-provider items so the cycle order stays stable across
    /// refreshes instead of following probe completion order.
    static func rotatableCandidates(
        _ candidates: [StatusLimitCandidate],
        now: Date
    ) -> [StatusLimitCandidate] {
        candidates
            .filter(\.isAutoSelectable)
            .filter { now.timeIntervalSince($0.lastUpdated) <= ProviderParseHealthRecord.staleAfter }
            .sorted { (($0.service.sortOrder, $0.key)) < (($1.service.sortOrder, $1.key)) }
    }

    static func outcome(
        candidates: [StatusLimitCandidate],
        tick: Int,
        pinnedKey: String?,
        now: Date
    ) -> MenuBarRotationOutcome {
        guard pinnedKey == nil else { return .inactive }

        let rotatable = rotatableCandidates(candidates, now: now)
        guard !rotatable.isEmpty else { return .inactive }

        // Asking the existing selector what it *would* show keeps the hold rule
        // honest: it already skips fully spent quotas so the title can't freeze
        // on 0% for days, and rotation must not reintroduce that freeze through
        // the back door. No previous key, because the rotated label is not an
        // auto-selection history and must not anchor the hysteresis.
        if let selection = StatusItemLimitSelector.select(
            candidates: rotatable,
            previousKey: nil,
            pinnedKey: nil,
            now: now
        ), QuotaBand.forLimit(selection.limit).severityRank >= QuotaBand.critical.severityRank {
            return .hold(selection)
        }

        return .rotate(rotatable[index(tick: tick, count: rotatable.count)])
    }

    /// The next tick. A paused tick does not advance, so the label cannot change
    /// while the user is reading the popover it belongs to.
    static func advance(tick: Int, isPaused: Bool) -> Int {
        guard !isPaused else { return tick }
        return tick == Int.max ? 0 : tick + 1
    }

    /// Wraps in both directions so a tick restored from anywhere still names a
    /// real provider instead of trapping on a negative remainder.
    private static func index(tick: Int, count: Int) -> Int {
        let remainder = tick % count
        return remainder < 0 ? remainder + count : remainder
    }
}
