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
    /// Start of the seven-calendar-day hourly window. Separate from `cutoff`
    /// because the main cost scan normally retains 30 daily buckets.
    let hourlyCutoff: Date

    init(
        period: Totals,
        lifetime: Totals,
        cutoff: Date,
        hourlyCutoff: Date = .distantPast
    ) {
        self.period = period
        self.lifetime = lifetime
        self.cutoff = cutoff
        self.hourlyCutoff = hourlyCutoff
    }

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

/// The nine breakdowns every scan folds a usage event into.
///
/// Claude and Codex accumulate into different types but the same nine
/// dimensions, so the fold itself lives once in `record(_:at:)` rather than
/// twice as near-identical stanzas in each scanner.
nonisolated protocol CostScanBreakdowns {
    var daily: [Date: TokenAccumulator] { get set }
    var hourly: [Date: TokenAccumulator] { get set }
    var dailyModels: [Date: [String: TokenAccumulator]] { get set }
    var dailyProjects: [Date: [String: TokenAccumulator]] { get set }
    var dailyProjectModels: [Date: [String: [String: TokenAccumulator]]] { get set }
    var models: [String: TokenAccumulator] { get set }
    var origins: [String: TokenAccumulator] { get set }
    var projects: [String: TokenAccumulator] { get set }
    var projectModels: [String: [String: TokenAccumulator]] { get set }
    /// Per-project session rows (issue #391). Nested so a session that somehow
    /// splits across projects still reconciles to each parent project total.
    var projectSessions: [String: [String: TokenAccumulator]] { get set }
    var projectSessionModels: [String: [String: [String: TokenAccumulator]]] { get set }
    var dailyProjectSessions: [Date: [String: [String: TokenAccumulator]]] { get set }
    var dailyProjectSessionModels: [Date: [String: [String: [String: TokenAccumulator]]]] { get set }
}

/// Which bucket of each breakdown one event lands in.
nonisolated struct CostScanEventKeys {
    let day: Date
    /// `nil` when the event predates the retained seven-day hourly window.
    let hour: Date?
    let model: String
    let origin: String
    let project: String
    /// Path-free session stem (issue #391). Every event belongs to exactly one
    /// session row; `CostSessionAttribution.unknownSessionID` is the explicit
    /// bucket when the transcript has no usable identity.
    let session: String
}

/// One event's contribution, already in the units the breakdowns store. The
/// scanners normalize before handing it over — Codex bills reasoning tokens as
/// output here, Claude has none to fold in.
nonisolated struct CostScanEventTotals {
    let input: Int
    let output: Int
    let cacheCreation: Int
    let cacheRead: Int
    let estimatedCostUSD: Double
}

nonisolated extension CostScanBreakdowns {
    mutating func record(_ event: CostScanEventTotals, at keys: CostScanEventKeys) {
        daily[keys.day, default: TokenAccumulator()].add(event)
        if let hour = keys.hour {
            hourly[hour, default: TokenAccumulator()].add(event)
        }
        dailyModels[keys.day, default: [:]][keys.model, default: TokenAccumulator()].add(event)
        dailyProjects[keys.day, default: [:]][keys.project, default: TokenAccumulator()].add(event)
        dailyProjectModels[keys.day, default: [:]][keys.project, default: [:]][
            keys.model,
            default: TokenAccumulator()
        ].add(event)
        models[keys.model, default: TokenAccumulator()].add(event)
        origins[keys.origin, default: TokenAccumulator()].add(event)
        projects[keys.project, default: TokenAccumulator()].add(event)
        projectModels[keys.project, default: [:]][keys.model, default: TokenAccumulator()].add(event)
        projectSessions[keys.project, default: [:]][keys.session, default: TokenAccumulator()].add(event)
        projectSessionModels[keys.project, default: [:]][keys.session, default: [:]][
            keys.model,
            default: TokenAccumulator()
        ].add(event)
        dailyProjectSessions[keys.day, default: [:]][keys.project, default: [:]][
            keys.session,
            default: TokenAccumulator()
        ].add(event)
        dailyProjectSessionModels[keys.day, default: [:]][keys.project, default: [:]][keys.session, default: [:]][
            keys.model,
            default: TokenAccumulator()
        ].add(event)
    }
}

/// Per-window tally for one Claude Code transcript, or many merged together.
///
/// `Codable` because a single file's tally is what `CostScanFileCache` persists
/// between refreshes — the byte offset alone would be worthless without the
/// totals the already-read bytes produced.
nonisolated struct ClaudeSessionTotals: Sendable, Codable, CostScanBreakdowns {
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
    var hourly: [Date: TokenAccumulator] = [:]
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
    /// Per-project session rows plus each session's model slice (issue #391).
    var projectSessions: [String: [String: TokenAccumulator]] = [:]
    var projectSessionModels: [String: [String: [String: TokenAccumulator]]] = [:]
    var dailyProjectSessions: [Date: [String: [String: TokenAccumulator]]] = [:]
    var dailyProjectSessionModels: [Date: [String: [String: [String: TokenAccumulator]]]] = [:]
    /// Which dated rate entries priced these events, and how many predated the
    /// table entirely (issue #339).
    var pricing = PricingProvenance()
    /// The `messageID:requestID` keys these totals were built from — the same
    /// role `eventKeys` plays in ``CostScanWindowContext``, and the reason a
    /// merge can tell "another transcript" from "the same transcript again".
    ///
    /// Two things depend on it. Within a file it is the first-wins guard across
    /// a resume boundary: an event behind the committed offset is already
    /// tallied, so a later slice must drop its duplicate. Across files it is
    /// what lets ``ClaudeCostScanner`` refuse a sync conflict copy or a restored
    /// backup instead of billing its events twice.
    var eventKeys: Set<String> = []

    var hasUsage: Bool {
        input > 0 || output > 0 || cacheCreation > 0 || cacheRead > 0
    }

    /// Folds one file's totals in. Empty files are skipped so they never inflate
    /// `sessions`.
    mutating func merge(_ other: ClaudeSessionTotals) {
        // Ahead of the usage guard: a slice that read only non-usage lines
        // still has to leave its keys behind, or the next slice would re-count
        // an event it has already passed.
        eventKeys.formUnion(other.eventKeys)
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
        for (hour, tokens) in other.hourly {
            hourly[hour, default: TokenAccumulator()].merge(tokens)
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
        CostScanNestedMerge.keyedAccumulators(&projectSessions, other.projectSessions)
        CostScanNestedMerge.doublyKeyedAccumulators(&projectSessionModels, other.projectSessionModels)
        CostScanNestedMerge.dailyKeyedAccumulators(&dailyProjectSessions, other.dailyProjectSessions)
        CostScanNestedMerge.dailyDoublyKeyedAccumulators(
            &dailyProjectSessionModels,
            other.dailyProjectSessionModels
        )

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
    var hourlyUsage: [HourlyTokenUsage] = []
    /// Union of the rate entries every provider in this window priced with.
    var pricing = PricingProvenance()

    mutating func append(_ scan: (TokenCost, [DailyTokenUsage], [HourlyTokenUsage])?) {
        guard let scan else { return }
        costs.append(scan.0)
        dailyUsage.append(contentsOf: scan.1)
        hourlyUsage.append(contentsOf: scan.2)
    }

    mutating func record(_ provenance: PricingProvenance) {
        pricing.merge(provenance)
    }
}

/// Mutable accumulators threaded through a corpus scan. Bundling these into one
/// value collapses `CodexCostScanner`'s `addUsage`/`scanRollouts`/`scanSQLiteLogs`
/// from 10–13 parameters (a SwiftLint `function_parameter_count` error) down to
/// a single `inout` argument.
///
/// Shared by the Codex and Grok scanners rather than duplicated: both fold the
/// same nine breakdown dimensions plus dedup keys, and a second copy would mean
/// a second `merge` and a second set of `_modify` forwarders to keep in step.
/// Renaming the *type* is safe for the on-disk cache — `Codable` keys come from
/// the stored property names below, not from the type's name.
///
/// Internal (not private) so `CodexCostScanner.scanRollouts` can be fixture-tested.
nonisolated struct CostScanWindowContext: Sendable, Codable {
    var totals = TokenAccumulator()
    var dailyTotals: [Date: TokenAccumulator] = [:]
    var hourlyTotals: [Date: TokenAccumulator] = [:]
    var dailyModelTotals: [Date: [String: TokenAccumulator]] = [:]
    var dailyProjectTotals: [Date: [String: TokenAccumulator]] = [:]
    var dailyProjectModelTotals: [Date: [String: [String: TokenAccumulator]]] = [:]
    var modelTotals: [String: TokenAccumulator] = [:]
    var originTotals: [String: TokenAccumulator] = [:]
    /// Per-project rollup keyed by `CostProjectAttribution.codexProjectID` —
    /// see the matching fields on `ClaudeSessionTotals` (issue #270).
    var projectTotals: [String: TokenAccumulator] = [:]
    var projectModelTotals: [String: [String: TokenAccumulator]] = [:]
    var projectSessions: [String: [String: TokenAccumulator]] = [:]
    var projectSessionModels: [String: [String: [String: TokenAccumulator]]] = [:]
    var dailyProjectSessions: [Date: [String: [String: TokenAccumulator]]] = [:]
    var dailyProjectSessionModels: [Date: [String: [String: [String: TokenAccumulator]]]] = [:]
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
    mutating func merge(_ other: CostScanWindowContext) {
        guard !other.eventKeys.isEmpty else { return }

        totals.merge(other.totals)
        for (day, tokens) in other.dailyTotals {
            dailyTotals[day, default: TokenAccumulator()].merge(tokens)
        }
        for (hour, tokens) in other.hourlyTotals {
            hourlyTotals[hour, default: TokenAccumulator()].merge(tokens)
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
        CostScanNestedMerge.keyedAccumulators(&projectSessions, other.projectSessions)
        CostScanNestedMerge.doublyKeyedAccumulators(&projectSessionModels, other.projectSessionModels)
        CostScanNestedMerge.dailyKeyedAccumulators(&dailyProjectSessions, other.dailyProjectSessions)
        CostScanNestedMerge.dailyDoublyKeyedAccumulators(
            &dailyProjectSessionModels,
            other.dailyProjectSessionModels
        )

        eventKeys.formUnion(other.eventKeys)
        sessionIDs.formUnion(other.sessionIDs)
        earliestDate = min(earliestDate, other.earliestDate)
        latestDate = max(latestDate, other.latestDate)
    }
}

/// Forwarders rather than renamed stored properties: `CostScanWindowContext` is the
/// `Codable` payload `CostScanFileCache` persists, so renaming its fields would
/// change the on-disk keys and force every user into a full rescan.
///
/// `_modify` rather than a setter: the fold subscripts these thousands of times
/// per scan, and a get-mutate-set forwarder would copy the whole dictionary on
/// every one of them.
nonisolated extension CostScanWindowContext: CostScanBreakdowns {
    var daily: [Date: TokenAccumulator] {
        get { dailyTotals }
        _modify { yield &dailyTotals }
    }

    var hourly: [Date: TokenAccumulator] {
        get { hourlyTotals }
        _modify { yield &hourlyTotals }
    }

    var dailyModels: [Date: [String: TokenAccumulator]] {
        get { dailyModelTotals }
        _modify { yield &dailyModelTotals }
    }

    var dailyProjects: [Date: [String: TokenAccumulator]] {
        get { dailyProjectTotals }
        _modify { yield &dailyProjectTotals }
    }

    var dailyProjectModels: [Date: [String: [String: TokenAccumulator]]] {
        get { dailyProjectModelTotals }
        _modify { yield &dailyProjectModelTotals }
    }

    var models: [String: TokenAccumulator] {
        get { modelTotals }
        _modify { yield &modelTotals }
    }

    var origins: [String: TokenAccumulator] {
        get { originTotals }
        _modify { yield &originTotals }
    }

    var projects: [String: TokenAccumulator] {
        get { projectTotals }
        _modify { yield &projectTotals }
    }

    var projectModels: [String: [String: TokenAccumulator]] {
        get { projectModelTotals }
        _modify { yield &projectModelTotals }
    }
}

/// Nested `TokenAccumulator` dictionary merges used by both scan payloads.
nonisolated enum CostScanNestedMerge {
    static func accumulators(
        _ target: inout [String: TokenAccumulator],
        _ other: [String: TokenAccumulator]
    ) {
        for (key, tokens) in other {
            target[key, default: TokenAccumulator()].merge(tokens)
        }
    }

    static func keyedAccumulators(
        _ target: inout [String: [String: TokenAccumulator]],
        _ other: [String: [String: TokenAccumulator]]
    ) {
        for (key, inner) in other {
            accumulators(&target[key, default: [:]], inner)
        }
    }

    static func doublyKeyedAccumulators(
        _ target: inout [String: [String: [String: TokenAccumulator]]],
        _ other: [String: [String: [String: TokenAccumulator]]]
    ) {
        for (key, inner) in other {
            keyedAccumulators(&target[key, default: [:]], inner)
        }
    }

    static func dailyKeyedAccumulators(
        _ target: inout [Date: [String: [String: TokenAccumulator]]],
        _ other: [Date: [String: [String: TokenAccumulator]]]
    ) {
        for (day, inner) in other {
            keyedAccumulators(&target[day, default: [:]], inner)
        }
    }

    static func dailyDoublyKeyedAccumulators(
        _ target: inout [Date: [String: [String: [String: TokenAccumulator]]]],
        _ other: [Date: [String: [String: [String: TokenAccumulator]]]]
    ) {
        for (day, inner) in other {
            doublyKeyedAccumulators(&target[day, default: [:]], inner)
        }
    }
}

/// Calendar-safe hour normalization shared by all three scanners and the
/// seven-day grid. `dateInterval` preserves distinct repeated hours at a DST
/// fallback while still returning the local hour boundary.
nonisolated enum CostScanHourBucket {
    static func start(for date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .hour, for: date)?.start ?? date
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

    mutating func add(_ event: CostScanEventTotals) {
        add(
            input: event.input,
            output: event.output,
            cacheCreation: event.cacheCreation,
            cacheRead: event.cacheRead,
            estimatedCostUSD: event.estimatedCostUSD
        )
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
