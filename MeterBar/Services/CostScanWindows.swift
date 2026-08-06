import Foundation
import MeterBarShared

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
///
/// `Codable` because a single file's tally is what `CostScanFileCache` persists
/// between refreshes — the byte offset alone would be worthless without the
/// totals the already-read bytes produced.
nonisolated struct ClaudeSessionTotals: Sendable, Codable {
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
    var dailyModels: [Date: [String: TokenAccumulator]] = [:]
    var dailyProjects: [Date: [String: TokenAccumulator]] = [:]
    var dailyProjectModels: [Date: [String: [String: TokenAccumulator]]] = [:]
    var models: [String: TokenAccumulator] = [:]
    var origins: [String: TokenAccumulator] = [:]
    /// Per-project rollup, keyed by the sanitized identifier `CostProjectAttribution`
    /// derives from the transcript's file-system path (issue #270). Every file
    /// attributes to exactly one bucket, including the explicit `unknown` one —
    /// never dropped, never guessed.
    var projects: [String: TokenAccumulator] = [:]
    /// Nested per-project, per-model totals powering the "drill-down to model
    /// breakdown" view under each project's rollup row.
    var projectModels: [String: [String: TokenAccumulator]] = [:]
    /// Which dated rate entries priced these events, and how many predated the
    /// table entirely (issue #339).
    var pricing = PricingProvenance()

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
        for (day, modelTotals) in other.dailyModels {
            for (model, tokens) in modelTotals {
                dailyModels[day, default: [:]][model, default: TokenAccumulator()].merge(tokens)
            }
        }
        for (day, projectTotals) in other.dailyProjects {
            for (project, tokens) in projectTotals {
                dailyProjects[day, default: [:]][project, default: TokenAccumulator()].merge(tokens)
            }
        }
        for (day, projectTotals) in other.dailyProjectModels {
            for (project, modelTotals) in projectTotals {
                for (model, tokens) in modelTotals {
                    dailyProjectModels[day, default: [:]][project, default: [:]][
                        model,
                        default: TokenAccumulator()
                    ].merge(tokens)
                }
            }
        }
        for (name, tokens) in other.models {
            models[name, default: TokenAccumulator()].merge(tokens)
        }
        for (name, tokens) in other.origins {
            origins[name, default: TokenAccumulator()].merge(tokens)
        }
        for (project, tokens) in other.projects {
            projects[project, default: TokenAccumulator()].merge(tokens)
        }
        for (project, modelTotals) in other.projectModels {
            for (model, tokens) in modelTotals {
                projectModels[project, default: [:]][model, default: TokenAccumulator()].merge(tokens)
            }
        }

        pricing.merge(other.pricing)
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
    /// Union of the rate entries every provider in this window priced with.
    var pricing = PricingProvenance()

    mutating func append(_ scan: (TokenCost, [DailyTokenUsage])?) {
        guard let scan else { return }
        costs.append(scan.0)
        dailyUsage.append(contentsOf: scan.1)
    }

    mutating func record(_ provenance: PricingProvenance) {
        pricing.merge(provenance)
    }
}

/// Mutable accumulators threaded through the Codex scan. Bundling these into one
/// value collapses `CodexCostScanner`'s `addUsage`/`scanRollouts`/`scanSQLiteLogs`
/// from 10–13 parameters (a SwiftLint `function_parameter_count` error) down to
/// a single `inout` argument.
///
/// Internal (not private) so `CodexCostScanner.scanRollouts` can be fixture-tested.
nonisolated struct CodexScanContext: Sendable, Codable {
    var totals = TokenAccumulator()
    var dailyTotals: [Date: TokenAccumulator] = [:]
    var dailyModelTotals: [Date: [String: TokenAccumulator]] = [:]
    var dailyProjectTotals: [Date: [String: TokenAccumulator]] = [:]
    var dailyProjectModelTotals: [Date: [String: [String: TokenAccumulator]]] = [:]
    var modelTotals: [String: TokenAccumulator] = [:]
    var originTotals: [String: TokenAccumulator] = [:]
    /// Per-project rollup keyed by `CostProjectAttribution.codexProjectID` —
    /// see the matching fields on `ClaudeSessionTotals` (issue #270).
    var projectTotals: [String: TokenAccumulator] = [:]
    var projectModelTotals: [String: [String: TokenAccumulator]] = [:]
    var eventKeys: Set<String> = []
    var sessionIDs: Set<String> = []
    /// Which dated rate entries priced these events (issue #339).
    var pricing = PricingProvenance()
    var earliestDate: Date
    var latestDate: Date

    /// Folds a cached rollout's tally into this window.
    ///
    /// The `eventKeys` guard is not an optimization. A cached context for a file
    /// that contributed nothing still carries `earliestDate = Date()` from
    /// whichever refresh created it, and merging that would drag the reported
    /// period start backwards to an instant no event ever happened at.
    mutating func merge(_ other: CodexScanContext) {
        guard !other.eventKeys.isEmpty else { return }

        totals.merge(other.totals)
        for (day, tokens) in other.dailyTotals {
            dailyTotals[day, default: TokenAccumulator()].merge(tokens)
        }
        for (day, modelTotals) in other.dailyModelTotals {
            for (model, tokens) in modelTotals {
                dailyModelTotals[day, default: [:]][model, default: TokenAccumulator()].merge(tokens)
            }
        }
        for (day, projectTotals) in other.dailyProjectTotals {
            for (project, tokens) in projectTotals {
                dailyProjectTotals[day, default: [:]][project, default: TokenAccumulator()].merge(tokens)
            }
        }
        for (day, projectTotals) in other.dailyProjectModelTotals {
            for (project, modelTotals) in projectTotals {
                for (model, tokens) in modelTotals {
                    dailyProjectModelTotals[day, default: [:]][project, default: [:]][
                        model,
                        default: TokenAccumulator()
                    ].merge(tokens)
                }
            }
        }
        for (name, tokens) in other.modelTotals {
            modelTotals[name, default: TokenAccumulator()].merge(tokens)
        }
        for (name, tokens) in other.originTotals {
            originTotals[name, default: TokenAccumulator()].merge(tokens)
        }
        for (project, tokens) in other.projectTotals {
            projectTotals[project, default: TokenAccumulator()].merge(tokens)
        }
        for (project, modelTotals) in other.projectModelTotals {
            for (model, tokens) in modelTotals {
                projectModelTotals[project, default: [:]][model, default: TokenAccumulator()].merge(tokens)
            }
        }

        eventKeys.formUnion(other.eventKeys)
        sessionIDs.formUnion(other.sessionIDs)
        earliestDate = min(earliestDate, other.earliestDate)
        latestDate = max(latestDate, other.latestDate)
    }
}

nonisolated struct TokenAccumulator: Sendable, Codable {
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
