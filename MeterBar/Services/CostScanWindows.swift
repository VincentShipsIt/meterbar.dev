import Foundation

/// Two accumulators filled by a single traversal: the reporting period and
/// all-time.
///
/// The cost summary needs both a windowed total and a lifetime total. Those used
/// to come from two full scans of `~/.claude/projects` and
/// `~/.codex/archived_sessions` — the lifetime pass reading a strict superset of
/// what the period pass had just read. Bucketing per event instead halves the
/// I/O for identical output.
nonisolated struct ScanWindows<Totals> {
    var period: Totals
    var lifetime: Totals
    /// Events at or after this instant belong to the period window as well.
    let cutoff: Date

    /// Applies `body` to `lifetime` always, and to `period` when the event falls
    /// inside the window.
    ///
    /// Running the same body against *separate* state is what preserves the old
    /// two-scan semantics. Deduplication in particular has to stay per-window: a
    /// pre-cutoff event and an in-window event can share a dedup key, and
    /// collapsing them into one map would let the pre-cutoff copy win and change
    /// the period total.
    mutating func update(at timestamp: Date, _ body: (inout Totals) -> Void) {
        body(&lifetime)
        if timestamp >= cutoff {
            body(&period)
        }
    }
}

// Unconditional `Totals: Sendable` would force `TokenCost` and `DailyTokenUsage`
// to be `Sendable` just to name `ScanWindows<CostScanResult>`.
extension ScanWindows: Sendable where Totals: Sendable {}

/// Per-window tally for one Claude Code transcript, or many merged together.
nonisolated struct ClaudeSessionTotals: Sendable {
    var input = 0
    var output = 0
    var cacheCreation = 0
    var cacheRead = 0
    var estimatedCost = 0.0
    /// Files that contributed usage, not events — matches the old
    /// `sessionCount += 1` per parsed file.
    var sessions = 0
    var earliest: Date?
    var latest: Date?
    var daily: [Date: TokenAccumulator] = [:]
    var models: [String: TokenAccumulator] = [:]
    var origins: [String: TokenAccumulator] = [:]

    var hasUsage: Bool {
        input > 0 || output > 0 || cacheCreation > 0 || cacheRead > 0
    }

    /// Folds one file's totals in. Empty files are skipped so they never inflate
    /// `sessions`.
    mutating func merge(_ other: ClaudeSessionTotals) {
        guard other.hasUsage else { return }

        input += other.input
        output += other.output
        cacheCreation += other.cacheCreation
        cacheRead += other.cacheRead
        estimatedCost += other.estimatedCost
        sessions += other.sessions

        for (day, tokens) in other.daily {
            daily[day, default: TokenAccumulator()].merge(tokens)
        }
        for (name, tokens) in other.models {
            models[name, default: TokenAccumulator()].merge(tokens)
        }
        for (name, tokens) in other.origins {
            origins[name, default: TokenAccumulator()].merge(tokens)
        }

        earliest = Self.earlier(earliest, other.earliest)
        latest = Self.later(latest, other.latest)
    }

    mutating func note(_ timestamp: Date) {
        earliest = Self.earlier(earliest, timestamp)
        latest = Self.later(latest, timestamp)
    }

    private static func earlier(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return min(lhs, rhs)
    }

    private static func later(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return max(lhs, rhs)
    }
}

/// The per-provider output of one scan window.
nonisolated struct CostScanResult {
    var costs: [TokenCost] = []
    var dailyUsage: [DailyTokenUsage] = []

    mutating func append(_ scan: (TokenCost, [DailyTokenUsage])?) {
        guard let scan else { return }
        costs.append(scan.0)
        dailyUsage.append(contentsOf: scan.1)
    }
}

/// Mutable accumulators threaded through the Codex scan. Bundling these into one
/// value collapses `addCodexUsage`/`scanCodexArchivedSessions`/`scanCodexSQLiteLogs`
/// from 10–13 parameters (a SwiftLint `function_parameter_count` error) down to
/// a single `inout` argument.
///
/// Internal (not private) so `scanCodexArchivedSessions` can be fixture-tested.
nonisolated struct CodexScanContext: Sendable {
    var totals = TokenAccumulator()
    var dailyTotals: [Date: TokenAccumulator] = [:]
    var modelTotals: [String: TokenAccumulator] = [:]
    var originTotals: [String: TokenAccumulator] = [:]
    var eventKeys: Set<String> = []
    var sessionIDs: Set<String> = []
    var earliestDate: Date
    var latestDate: Date
}

nonisolated struct TokenAccumulator: Sendable {
    var input = 0
    var output = 0
    var cacheCreation = 0
    var cacheRead = 0
    var reasoning = 0
    var estimatedCostUSD = 0.0
    var events = 0

    mutating func add(
        input: Int,
        output: Int,
        cacheCreation: Int,
        cacheRead: Int,
        reasoning: Int = 0,
        estimatedCostUSD: Double = 0,
        events: Int = 1
    ) {
        self.input += input
        self.output += output
        self.cacheCreation += cacheCreation
        self.cacheRead += cacheRead
        self.reasoning += reasoning
        self.estimatedCostUSD += estimatedCostUSD
        self.events += events
    }

    mutating func merge(_ other: TokenAccumulator) {
        add(
            input: other.input,
            output: other.output,
            cacheCreation: other.cacheCreation,
            cacheRead: other.cacheRead,
            reasoning: other.reasoning,
            estimatedCostUSD: other.estimatedCostUSD,
            events: other.events
        )
    }
}
