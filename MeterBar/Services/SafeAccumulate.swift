import Foundation

/// Saturating arithmetic for token/cost accumulation, shared by every cost
/// scanner and the CloudKit usage-rollup ingress/egress path (issue #541).
///
/// `CostScanValues.int(_:)` deliberately saturates an out-of-range JSON number
/// to `Int.max`/`Int.min` instead of trapping — a reasonable per-value guard
/// against the third-party CLIs that write these logs. But every downstream
/// fold used to add that saturated value with a plain trapping `+`, which just
/// handed the trap to the next line: one poisoned record (`"input_tokens":1e19`)
/// would saturate silently, and the very next *normal* record would crash the
/// app mid-refresh. Because the poisoned total is then persisted to disk
/// (`cost-summary-v2.json`) or CloudKit, the crash recurred on every later
/// launch and on every other Mac that synced the rollup — invisible to the
/// developer (no crash reporter) and fatal to the user.
///
/// `CostScanBudget.consume` already solved exactly this, correctly, for byte
/// counters: `spent.addingReportingOverflow(bytes).overflow ? .max : spent + bytes`.
/// This generalizes that same pattern into the one helper every accumulation
/// site should call, instead of re-deriving `addingReportingOverflow` at eight
/// call sites with eight chances to get the sign of the saturated bound wrong.
nonisolated enum SafeAccumulate {
    /// `true` when `value` sits exactly on the `Int` bound `CostScanValues.int(_:)`
    /// saturates to. A count at that exact bound came from a corrupt or hostile
    /// source line, not a real token/cost figure — callers that can reject a
    /// single event outright (rather than merely add it safely) should treat
    /// this as invalid input and drop the event, the same way an unparseable
    /// timestamp already drops only its own record.
    static func isSaturated(_ value: Int) -> Bool {
        value == .max || value == .min
    }

    /// Adds `rhs` into `lhs`, saturating at the `Int` bounds instead of
    /// trapping. Safe to call with either operand already saturated — the
    /// result saturates again rather than wrapping past the bound.
    static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflowed) = lhs.addingReportingOverflow(rhs)
        guard overflowed else { return sum }
        return rhs >= 0 ? Int.max : Int.min
    }

    /// In-place `+=` using `add(_:_:)`.
    static func accumulate(_ lhs: inout Int, _ rhs: Int) {
        lhs = add(lhs, rhs)
    }

    /// Sums a sequence without trapping, regardless of how many terms are
    /// already saturated or how many partial sums would otherwise overflow.
    static func sum(_ values: some Sequence<Int>) -> Int {
        values.reduce(0, add)
    }

    /// Sums a sequence of `Int` values as `Double`, for a caller building a
    /// ratio or share rather than a displayed count.
    ///
    /// `sum(_:)` saturates a displayed total at the `Int` bound, which is the
    /// right call for a number shown on its own — but a ratio built from two
    /// *independently* saturating `Int` sums (numerator and denominator each
    /// folded with `sum(_:)`) loses the split between them the moment either
    /// one hits the bound: two provider totals that were merely large, not
    /// equal, both read back as the same `Int.max` and render as 100%/0%
    /// instead of their real proportion. `Double` addition never traps, and
    /// real token/cost totals never approach its 2^53 exact-integer ceiling,
    /// so folding the ratio's operands here keeps the *proportion* correct
    /// past the point `Int` can represent it at all — this is strictly a
    /// bugfix for real data, not just a crash guard.
    static func sumAsDouble(_ values: some Sequence<Int>) -> Double {
        values.reduce(0) { $0 + Double($1) }
    }

    /// `max(0, minuend - subtrahend)`, but clamps both operands to
    /// non-negative *before* subtracting rather than after.
    ///
    /// A plain `max(0, a - b)` evaluates the subtraction first: a hostile
    /// negative `a` paired with a huge (possibly saturated) `b` underflows and
    /// traps before the outer `max(0, ...)` ever runs. Clamping first removes
    /// the underflow instead of catching it afterward — the exact shape of the
    /// Grok (`GrokCostScanner.swift`) and Codex (`CodexCostScanner.swift`)
    /// cache-token subtraction sites.
    static func clampedNonNegativeDifference(_ minuend: Int, _ subtrahend: Int) -> Int {
        let safeMinuend = Swift.max(0, minuend)
        let safeSubtrahend = Swift.max(0, subtrahend)
        let (difference, overflowed) = safeMinuend.subtractingReportingOverflow(safeSubtrahend)
        guard !overflowed else { return 0 }
        return Swift.max(0, difference)
    }
}
