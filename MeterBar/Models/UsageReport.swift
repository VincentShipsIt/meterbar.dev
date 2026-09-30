import Foundation
import MeterBarShared

// The Usage page's numbers (issue #593). One `UsageReport` is cut from the cached
// `CostSummary` for one reporting window, and the headline strip, the chart, the
// breakdown table and the insights column all read it, so they cannot disagree
// about which rows belong to the window.
//
// Everything here accumulates in `Double`. A token total is displayed through
// `SafeAccumulate` (an `Int` that saturates), but a *ratio* built from two
// independently saturating `Int` sums loses the split the moment either one hits
// the bound (issue #591): two providers that each read `Int.max` would stack past
// one column height and every overflowing entry would tie. `Double` never traps
// and keeps the proportions far past `Int`'s range, so the chart, the shares and
// the insight ratios are all computed from raw components here.

// MARK: - Token composition

/// The four ways a token is billed. Shared by the chart's "Token type" stacking
/// and the breakdown table's composition bar so the two use one vocabulary.
nonisolated enum TokenKind: String, CaseIterable, Identifiable, Sendable {
    case input
    case output
    case cacheWrite
    case cacheRead

    var id: String { rawValue }

    var title: String {
        switch self {
        case .input: return "Input"
        case .output: return "Output"
        case .cacheWrite: return "Cache write"
        case .cacheRead: return "Cache read"
        }
    }
}

/// Input, output, cache-write and cache-read tokens as non-saturating doubles.
nonisolated struct TokenComposition: Equatable, Sendable {
    private(set) var input: Double
    private(set) var output: Double
    private(set) var cacheWrite: Double
    private(set) var cacheRead: Double

    static let zero = TokenComposition(input: 0, output: 0, cacheWrite: 0, cacheRead: 0)

    init(input: Int, output: Int, cacheWrite: Int, cacheRead: Int) {
        self.input = Self.component(input)
        self.output = Self.component(output)
        self.cacheWrite = Self.component(cacheWrite)
        self.cacheRead = Self.component(cacheRead)
    }

    init(_ row: DailyTokenUsage) {
        self.init(
            input: row.inputTokens,
            output: row.outputTokens,
            cacheWrite: row.cacheCreationTokens,
            cacheRead: row.cacheReadTokens
        )
        // A day's parent components saturate independently of its models and
        // projects. Recover any detail still available before computing shares
        // or stacks; never add two attribution dimensions to one another.
        for detail in [row.modelBreakdowns, row.projectBreakdowns] {
            var detailed = Self.zero
            for part in detail ?? [] { detailed.add(TokenComposition(part)) }
            if row.inputTokens == Int.max { input = max(input, detailed.input) }
            if row.outputTokens == Int.max { output = max(output, detailed.output) }
            if row.cacheCreationTokens == Int.max { cacheWrite = max(cacheWrite, detailed.cacheWrite) }
            if row.cacheReadTokens == Int.max { cacheRead = max(cacheRead, detailed.cacheRead) }
        }
    }

    init(_ breakdown: TokenUsageBreakdown) {
        self.init(
            input: breakdown.inputTokens,
            output: breakdown.outputTokens,
            cacheWrite: breakdown.cacheCreationTokens,
            cacheRead: breakdown.cacheReadTokens
        )
    }

    init(_ cost: TokenCost) {
        self.init(
            input: cost.inputTokens,
            output: cost.outputTokens,
            cacheWrite: cost.cacheCreationTokens,
            cacheRead: cost.cacheReadTokens
        )
    }

    /// A negative count is corrupt input, not a refund.
    private static func component(_ value: Int) -> Double {
        Double(max(0, value))
    }

    var total: Double { input + output + cacheWrite + cacheRead }

    func value(_ kind: TokenKind) -> Double {
        switch kind {
        case .input: return input
        case .output: return output
        case .cacheWrite: return cacheWrite
        case .cacheRead: return cacheRead
        }
    }

    /// `kind`'s share of the total, `0` for an empty composition.
    func fraction(_ kind: TokenKind) -> Double {
        let total = total
        return total > 0 ? value(kind) / total : 0
    }

    mutating func add(_ other: TokenComposition) {
        input += other.input
        output += other.output
        cacheWrite += other.cacheWrite
        cacheRead += other.cacheRead
    }

    /// Bound over-attributed components to the authoritative row, preserving
    /// each component's relative model/project split.
    func limited(to total: TokenComposition, attributed: TokenComposition) -> TokenComposition {
        var result = self
        for kind in TokenKind.allCases {
            let sum = attributed.value(kind)
            guard sum > total.value(kind), sum > 0 else { continue }
            let value = value(kind) * total.value(kind) / sum
            switch kind {
            case .input: result.input = value
            case .output: result.output = value
            case .cacheWrite: result.cacheWrite = value
            case .cacheRead: result.cacheRead = value
            }
        }
        return result
    }

    /// This composition with `other` taken away, each component floored at zero.
    func subtractingClamped(_ other: TokenComposition) -> TokenComposition {
        var result = self
        result.input = max(0, input - other.input)
        result.output = max(0, output - other.output)
        result.cacheWrite = max(0, cacheWrite - other.cacheWrite)
        result.cacheRead = max(0, cacheRead - other.cacheRead)
        return result
    }
}

// MARK: - Chart selection

nonisolated enum UsageMetric: String, CaseIterable, Identifiable, Sendable {
    case tokens
    case cost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tokens: return "Tokens"
        case .cost: return "Cost"
        }
    }
}

nonisolated enum UsageStacking: String, CaseIterable, Identifiable, Sendable {
    case provider
    case tokenType
    case model

    var id: String { rawValue }

    var title: String {
        switch self {
        case .provider: return "Provider"
        case .tokenType: return "Token type"
        case .model: return "Model"
        }
    }

    /// Cost is recorded once per row, never per token type, so splitting a cost
    /// chart four ways would mean inventing prices. Grok's cost is what the CLI
    /// reported, so no rate card could reproduce it either.
    static func available(for metric: UsageMetric) -> [UsageStacking] {
        switch metric {
        case .tokens: return [.provider, .tokenType, .model]
        case .cost: return [.provider, .model]
        }
    }
}

nonisolated struct UsageChartSelection: Equatable, Sendable {
    var metric: UsageMetric
    var stacking: UsageStacking

    static let `default` = UsageChartSelection(metric: .tokens, stacking: .provider)

    /// The selection with an unavailable stacking replaced, so switching to Cost
    /// while stacked by token type lands on Provider instead of drawing nothing.
    func normalized() -> UsageChartSelection {
        guard !UsageStacking.available(for: metric).contains(stacking) else { return self }
        return UsageChartSelection(metric: metric, stacking: .provider)
    }
}

// MARK: - Series

nonisolated struct UsageSeriesCategory: Identifiable, Equatable, Sendable {
    let name: String
    /// Set when the category *is* a provider, so the chart can use its accent.
    let provider: ServiceType?
    /// Set when the category *is* a token kind.
    let kind: TokenKind?

    var id: String { name }
}

nonisolated struct UsageSeriesPoint: Identifiable, Equatable, Sendable {
    let date: Date
    let category: String
    let value: Double

    var id: String { "\(date.timeIntervalSinceReferenceDate)|\(category)" }
}

nonisolated struct UsageSeries: Equatable, Sendable {
    let metric: UsageMetric
    let stacking: UsageStacking
    let points: [UsageSeriesPoint]
    /// Legend order, biggest first where that is meaningful.
    let categories: [UsageSeriesCategory]
    /// Every day of the window, oldest first, including days with no usage.
    let days: [Date]

    /// The tallest stacked column, for the y-scale. `nil` when nothing is drawn.
    var maxDayTotal: Double? {
        Dictionary(grouping: points, by: \.date)
            .values
            .map { $0.reduce(0) { $0 + $1.value } }
            .max()
    }
}

// MARK: - Breakdown

nonisolated enum UsageBreakdownTab: String, CaseIterable, Identifiable, Sendable {
    case model
    case origin
    case project
    case provider

    var id: String { rawValue }

    var title: String {
        switch self {
        case .model: return "By model"
        case .origin: return "By origin"
        case .project: return "By project"
        case .provider: return "By provider"
        }
    }

    var primaryColumnTitle: String {
        switch self {
        case .model: return "Model"
        case .origin: return "Origin"
        case .project: return "Project"
        case .provider: return "Provider"
        }
    }
}

nonisolated struct UsageBreakdownRow: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// The provider dot. `nil` never happens today, but a merged row could.
    let provider: ServiceType?
    let composition: TokenComposition
    let costUSD: Double
    /// Share of the table's total tokens, `0...1`.
    let share: Double
    /// Only model rows are tiered.
    let tier: ModelTier?

    var tokens: Double { composition.total }
    var tokenCount: Int { UsageFormat.clampedTokenCount(tokens) }
}

// MARK: - Headline, notes

nonisolated struct UsageHeadline: Equatable, Sendable {
    let costUSD: Double
    /// Displayed total; saturates at `Int.max`. Ratios never read this.
    let totalTokens: Int
    /// Cache reads over every token in the window. Unlike a reuse ratio it needs
    /// no cache-write count, so it is meaningful for every provider.
    let cacheReadShare: Double?
    /// Premium-tier share of the tokens whose model is known.
    let premiumShare: Double?
}

nonisolated struct UsageDataNote: Identifiable, Equatable, Sendable {
    enum Severity: Int, Comparable, Sendable {
        case info = 0
        case warning = 1

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let severity: Severity
    let text: String
}

// MARK: - Report

nonisolated struct UsageReport: Sendable {
    private static let trendRecentDays = 7
    private static let unattributedName = "Unattributed"
    private static let costTolerance = 0.005
    static let maximumSeriesModels = 5

    let selection: CostWindowSelection
    let windowDays: Int
    let windowStart: Date
    let today: Date
    /// Days the cache demonstrably covers, at most `windowDays`.
    let coveredDays: Int
    let headline: UsageHeadline
    let composition: TokenComposition
    let insights: OptimizationInsights
    let notes: [UsageDataNote]
    /// True when the origin rollup (a scan-period total) describes the window.
    let originsCoverWindow: Bool
    /// Days the underlying scan covered, which is what model, project and
    /// origin fallbacks describe.
    let scanPeriodDays: Int

    private let calendar: Calendar
    private let rows: [DailyTokenUsage]
    private let breakdowns: [UsageBreakdownTab: [UsageBreakdownRow]]

    var hasData: Bool { composition.total > 0 || headline.costUSD > 0 }
    var windowRows: [DailyTokenUsage] {
        rows
    }

    init(
        summary: CostSummary,
        selection: CostWindowSelection,
        compressedCodexRollouts: Int = 0,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let today = calendar.startOfDay(for: now)
        let windowDays = max(1, selection.dayCount(now: now, calendar: calendar))
        let windowStart = CalendarDayStep.day(today, offsetBy: -(windowDays - 1), calendar: calendar)
        let rows = summary.dailyRows(lastDays: windowDays, now: now, calendar: calendar)
        let coveredDays = summary.dailyCostWindow(lastDays: windowDays, now: now, calendar: calendar).coveredDays

        self.selection = selection
        self.windowDays = windowDays
        self.windowStart = windowStart
        self.today = today
        self.coveredDays = coveredDays
        self.calendar = calendar
        self.rows = rows

        var composition = TokenComposition.zero
        var cost = 0.0
        for row in rows {
            composition.add(TokenComposition(row))
            cost += max(0, row.estimatedCostUSD)
        }
        self.composition = composition

        // Origins are a scan-period rollup; the daily rows carry no origin split.
        let originCosts = summary.costs.filter { !$0.originBreakdowns.isEmpty }
        let windowEnd = CalendarDayStep.day(today, offsetBy: 1, calendar: calendar)
        let originsCoverWindow = !originCosts.isEmpty && originCosts.allSatisfy {
            $0.periodStart <= $0.periodEnd
                && calendar.startOfDay(for: $0.periodStart) >= windowStart
                && $0.periodEnd < windowEnd
        }
        self.originsCoverWindow = originsCoverWindow
        scanPeriodDays = summary.periodDays

        var tableNotes: [UsageDataNote] = []
        let models = Self.attributionRows(
            .model,
            rows: rows,
            summary: summary,
            windowDays: windowDays,
            notes: &tableNotes
        )
        let projects = Self.attributionRows(
            .project,
            rows: rows,
            summary: summary,
            windowDays: windowDays,
            notes: &tableNotes
        )
        let origins = Self.originRows(from: summary.costs)
        let providers = Self.providerRows(from: rows)
        breakdowns = [.model: models, .origin: origins, .project: projects, .provider: providers]

        // A scan-period table fallback is useful detail, but never evidence
        // about this window's model mix. Missing daily attribution means the
        // premium signal is unavailable, including mixed legacy/current rows.
        let attributedModels = rows.allSatisfy { $0.modelBreakdowns != nil }
            ? models.filter { $0.name != Self.unattributedName }
            : []
        let attributedTokens = attributedModels.reduce(0) { $0 + $1.tokens }
        let premiumTokens = attributedModels.filter { $0.tier?.isPremium == true }.reduce(0) { $0 + $1.tokens }
        let premiumShare = attributedTokens > 0 ? premiumTokens / attributedTokens : nil

        headline = UsageHeadline(
            costUSD: cost,
            totalTokens: UsageFormat.clampedTokenCount(composition.total),
            cacheReadShare: composition.total > 0 ? composition.cacheRead / composition.total : nil,
            premiumShare: premiumShare
        )

        let cacheReport = Self.cacheUse(rows: rows)
        let topOrigin = originsCoverWindow ? origins.first.map { row in
            OptimizationInsights.OriginShare(
                name: row.name,
                tokens: row.tokens,
                groupTokens: origins.reduce(0) { $0 + $1.tokens }
            )
        } : nil

        insights = OptimizationInsights(
            inputs: OptimizationInsights.Inputs(
                premiumTokens: premiumTokens,
                attributedModelTokens: attributedTokens,
                inputTokens: composition.input,
                outputTokens: composition.output,
                cacheUse: cacheReport.reporting,
                topOrigin: topOrigin,
                trend: Self.trend(
                    rows: rows,
                    calendar: calendar,
                    today: today,
                    windowDays: windowDays,
                    coveredDays: coveredDays,
                    total: composition.total
                )
            ),
            hasData: composition.total > 0
        )

        notes = Self.dataNotes(
            summary: summary,
            rows: rows,
            context: NoteContext(
                windowDays: windowDays,
                coveredDays: coveredDays,
                hasOriginData: !origins.isEmpty,
                originsCoverWindow: originsCoverWindow,
                unreportedCacheProviders: cacheReport.unreported,
                compressedCodexRollouts: compressedCodexRollouts,
                tableNotes: tableNotes
            )
        )
    }

    // MARK: Public reads

    func breakdown(_ tab: UsageBreakdownTab) -> [UsageBreakdownRow] {
        breakdowns[tab] ?? []
    }

    func breakdownIsWindowed(_ tab: UsageBreakdownTab) -> Bool {
        switch tab {
        case .origin: return originsCoverWindow
        case .model: return !notes.contains { $0.id == AttributionKind.model.noteID }
        case .project: return !notes.contains { $0.id == AttributionKind.project.noteID }
        case .provider: return true
        }
    }

    /// That day's total in `metric`, straight from the rows. The chart's stacked
    /// columns must sum to this.
    func dayTotal(on day: Date, metric: UsageMetric) -> Double {
        rows.filter { $0.day(on: calendar) == day }.reduce(0) { $0 + Self.value(of: $1, metric: metric) }
    }

    /// The chart's x-domain: the window plus one trailing day, so today's bar
    /// sits inside the plot instead of on the edge.
    var chartDomain: ClosedRange<Date> {
        windowStart ... CalendarDayStep.day(today, offsetBy: 1, calendar: calendar)
    }

    var windowDayList: [Date] {
        (0..<windowDays).map { CalendarDayStep.day(windowStart, offsetBy: $0, calendar: calendar) }
    }

    // MARK: Series

    func series(_ requested: UsageChartSelection) -> UsageSeries {
        let selection = requested.normalized()
        let metric = selection.metric
        let days = windowDayList

        let points: [UsageSeriesPoint]
        let categories: [UsageSeriesCategory]
        switch selection.stacking {
        case .provider:
            (points, categories) = providerSeries(metric: metric)
        case .tokenType:
            (points, categories) = tokenTypeSeries()
        case .model:
            (points, categories) = modelSeries(metric: metric)
        }

        let order = Dictionary(
            categories.enumerated().map { ($0.element.name, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let sorted = points.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return (order[lhs.category] ?? 0) < (order[rhs.category] ?? 0)
        }
        return UsageSeries(
            metric: metric,
            stacking: selection.stacking,
            points: sorted,
            categories: categories,
            days: days
        )
    }

    private func providerSeries(metric: UsageMetric) -> ([UsageSeriesPoint], [UsageSeriesCategory]) {
        var totals: [DayKey: Double] = [:]
        for row in rows {
            totals[DayKey(day: row.day(on: calendar), name: row.provider.displayName), default: 0] +=
                Self.value(of: row, metric: metric)
        }
        let drawn = Set(totals.filter { $0.value > 0 }.map(\.key.name))
        let categories = Set(rows.map(\.provider))
            .sorted { $0.sortOrder < $1.sortOrder }
            .filter { drawn.contains($0.displayName) }
            .map { UsageSeriesCategory(name: $0.displayName, provider: $0, kind: nil) }
        return (Self.points(from: totals), categories)
    }

    private func tokenTypeSeries() -> ([UsageSeriesPoint], [UsageSeriesCategory]) {
        var totals: [DayKey: Double] = [:]
        for row in rows {
            let composition = TokenComposition(row)
            let day = row.day(on: calendar)
            for kind in TokenKind.allCases {
                totals[DayKey(day: day, name: kind.title), default: 0] += composition.value(kind)
            }
        }
        let categories = TokenKind.allCases
            .filter { composition.value($0) > 0 }
            .map { UsageSeriesCategory(name: $0.title, provider: nil, kind: $0) }
        return (Self.points(from: totals), categories)
    }

    private func modelSeries(metric: UsageMetric) -> ([UsageSeriesPoint], [UsageSeriesCategory]) {
        var totals: [DayKey: Double] = [:]
        var windowTotals: [String: Double] = [:]
        for row in rows {
            let day = row.day(on: calendar)
            for slice in Self.modelSlices(of: row) {
                let amount = metric == .tokens ? slice.composition.total : max(0, slice.costUSD)
                guard amount > 0 else { continue }
                totals[DayKey(day: day, name: slice.name), default: 0] += amount
                windowTotals[slice.name, default: 0] += amount
            }
        }

        let ranked = windowTotals
            .filter { $0.key != Self.unattributedName }
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .map(\.key)
        let kept = Array(ranked.prefix(Self.maximumSeriesModels))
        let folded = Set(ranked.dropFirst(Self.maximumSeriesModels))

        var names = kept
        if windowTotals[Self.unattributedName] != nil { names.append(Self.unattributedName) }
        if !folded.isEmpty {
            names.append("Other")
            var regrouped: [DayKey: Double] = [:]
            for (key, value) in totals {
                let name = folded.contains(key.name) ? "Other" : key.name
                regrouped[DayKey(day: key.day, name: name), default: 0] += value
            }
            totals = regrouped
        }

        let categories = names.map { UsageSeriesCategory(name: $0, provider: nil, kind: nil) }
        return (Self.points(from: totals), categories)
    }

    nonisolated private struct DayKey: Hashable {
        let day: Date
        let name: String
    }

    private static func points(from totals: [DayKey: Double]) -> [UsageSeriesPoint] {
        totals
            .filter { $0.value > 0 }
            .map { UsageSeriesPoint(date: $0.key.day, category: $0.key.name, value: $0.value) }
    }

    private static func value(of row: DailyTokenUsage, metric: UsageMetric) -> Double {
        switch metric {
        case .tokens: return TokenComposition(row).total
        case .cost: return max(0, row.estimatedCostUSD)
        }
    }

    // MARK: Attribution

    nonisolated private struct Slice {
        let provider: ServiceType
        let name: String
        let composition: TokenComposition
        let costUSD: Double
    }

    /// A row's per-model split. Whatever the attribution does not cover — or
    /// all of it, for a row that predates attribution — is `Unattributed`, so
    /// the slices always add up to the row.
    private static func modelSlices(of row: DailyTokenUsage) -> [Slice] {
        slices(of: row, attribution: row.modelBreakdowns)
    }

    private static func slices(of row: DailyTokenUsage, attribution: [TokenUsageBreakdown]?) -> [Slice] {
        var result: [Slice] = []
        var attributed = TokenComposition.zero
        var attributedCost = 0.0
        for part in attribution ?? [] {
            let composition = TokenComposition(part)
            result.append(Slice(
                provider: row.provider,
                name: part.name,
                composition: composition,
                costUSD: max(0, part.estimatedCostUSD)
            ))
            attributed.add(composition)
            attributedCost += max(0, part.estimatedCostUSD)
        }
        let total = TokenComposition(row)
        let totalCost = max(0, row.estimatedCostUSD)
        let costScale = attributedCost > totalCost && attributedCost > 0 ? totalCost / attributedCost : 1
        result = result.map { slice in
            Slice(
                provider: slice.provider,
                name: slice.name,
                composition: slice.composition.limited(to: total, attributed: attributed),
                costUSD: slice.costUSD * costScale
            )
        }
        let remainder = total.subtractingClamped(attributed)
        let remainderCost = max(0, totalCost - attributedCost)
        if remainder.total > 0 || remainderCost > costTolerance {
            result.append(Slice(
                provider: row.provider,
                name: unattributedName,
                composition: remainder,
                costUSD: remainderCost
            ))
        }
        return result
    }

    nonisolated private struct RowKey: Hashable {
        let provider: ServiceType
        let name: String
    }

    nonisolated private struct Accumulator {
        var composition = TokenComposition.zero
        var costUSD = 0.0

        mutating func add(_ other: TokenComposition, costUSD otherCost: Double) {
            composition.add(other)
            costUSD += max(0, otherCost)
        }
    }

    nonisolated private enum AttributionKind {
        case model
        case project

        var subject: String {
            switch self {
            case .model: return "Model"
            case .project: return "Project"
            }
        }

        var noteID: String {
            switch self {
            case .model: return "model-detail-scan-period"
            case .project: return "project-detail-scan-period"
            }
        }

        /// Only model rows carry a cost tier.
        var isTiered: Bool { self == .model }

        func attribution(of row: DailyTokenUsage) -> [TokenUsageBreakdown]? {
            switch self {
            case .model: return row.modelBreakdowns
            case .project: return row.projectBreakdowns
            }
        }

        func attribution(of cost: TokenCost) -> [TokenUsageBreakdown] {
            switch self {
            case .model: return cost.modelBreakdowns
            case .project: return cost.projectBreakdowns
            }
        }
    }

    /// Model or project rows for the window: cut from the daily rows' own
    /// attribution when every row has it, otherwise the scan-period rollup with
    /// a note saying so (a v1 cache predates attribution).
    private static func attributionRows(
        _ kind: AttributionKind,
        rows: [DailyTokenUsage],
        summary: CostSummary,
        windowDays: Int,
        notes: inout [UsageDataNote]
    ) -> [UsageBreakdownRow] {
        var totals: [RowKey: Accumulator] = [:]

        guard rows.allSatisfy({ kind.attribution(of: $0) != nil }) else {
            notes.append(UsageDataNote(
                id: kind.noteID,
                severity: .warning,
                text: "\(kind.subject) detail covers the \(summary.periodDays)-day scan, "
                    + "not the selected \(windowDays)-day window."
            ))
            for cost in summary.costs {
                var attributed = TokenComposition.zero
                var attributedCost = 0.0
                for part in kind.attribution(of: cost) {
                    let composition = TokenComposition(part)
                    totals[RowKey(provider: cost.provider, name: part.name), default: Accumulator()]
                        .add(composition, costUSD: part.estimatedCostUSD)
                    attributed.add(composition)
                    attributedCost += max(0, part.estimatedCostUSD)
                }
                let remainder = TokenComposition(cost).subtractingClamped(attributed)
                let remainderCost = max(0, cost.estimatedCostUSD - attributedCost)
                if remainder.total > 0 || remainderCost > costTolerance {
                    totals[RowKey(provider: cost.provider, name: unattributedName), default: Accumulator()]
                        .add(remainder, costUSD: remainderCost)
                }
            }
            return makeRows(totals, tiered: kind.isTiered)
        }

        for row in rows {
            for slice in slices(of: row, attribution: kind.attribution(of: row)) {
                totals[RowKey(provider: slice.provider, name: slice.name), default: Accumulator()]
                    .add(slice.composition, costUSD: slice.costUSD)
            }
        }
        return makeRows(totals, tiered: kind.isTiered)
    }

    private static func originRows(from costs: [TokenCost]) -> [UsageBreakdownRow] {
        var totals: [RowKey: Accumulator] = [:]
        for cost in costs {
            for part in cost.originBreakdowns {
                totals[RowKey(provider: cost.provider, name: part.name), default: Accumulator()]
                    .add(TokenComposition(part), costUSD: part.estimatedCostUSD)
            }
        }
        return makeRows(totals, tiered: false)
    }

    private static func providerRows(from rows: [DailyTokenUsage]) -> [UsageBreakdownRow] {
        var totals: [ServiceType: Accumulator] = [:]
        for row in rows {
            totals[row.provider, default: Accumulator()].add(TokenComposition(row), costUSD: row.estimatedCostUSD)
        }
        var keyed: [RowKey: Accumulator] = [:]
        for (provider, accumulator) in totals {
            keyed[RowKey(provider: provider, name: provider.displayName)] = accumulator
        }
        return makeRows(keyed, tiered: false)
    }

    /// Sorted rows with shares. Rows with neither tokens nor cost are dropped.
    private static func makeRows(_ totals: [RowKey: Accumulator], tiered: Bool) -> [UsageBreakdownRow] {
        let live = totals.filter { $0.value.composition.total > 0 || $0.value.costUSD > 0 }
        let grandTotal = live.values.reduce(0) { $0 + $1.composition.total }
        return live
            .map { key, accumulator in
                UsageBreakdownRow(
                    id: "\(key.provider.rawValue)|\(key.name)",
                    name: key.name,
                    provider: key.provider,
                    composition: accumulator.composition,
                    costUSD: accumulator.costUSD,
                    share: grandTotal > 0 ? accumulator.composition.total / grandTotal : 0,
                    tier: tiered && key.name != unattributedName ? ModelTier.classify(key.name) : nil
                )
            }
            .sorted { lhs, rhs in
                if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
                if lhs.costUSD != rhs.costUSD { return lhs.costUSD > rhs.costUSD }
                return lhs.id < rhs.id
            }
    }

    // MARK: Cache reuse

    /// Cache reads and writes over the providers that report both, and the
    /// providers that read from cache but never report a write.
    ///
    /// A provider counts as reporting writes only if it logged some *and* every
    /// one of its rows is authoritative: a legacy row's zero is a decoding
    /// fallback, not an observed zero.
    private static func cacheUse(
        rows: [DailyTokenUsage]
    ) -> (reporting: OptimizationInsights.CacheUse?, unreported: [ServiceType]) {
        var reads: [ServiceType: Double] = [:]
        var writes: [ServiceType: Double] = [:]
        var authoritative: [ServiceType: Bool] = [:]
        for row in rows {
            let composition = TokenComposition(row)
            reads[row.provider, default: 0] += composition.cacheRead
            writes[row.provider, default: 0] += composition.cacheWrite
            authoritative[row.provider] = (authoritative[row.provider] ?? true)
                && row.cacheCreationTokensAreAuthoritative
        }

        var reportingReads = 0.0
        var reportingWrites = 0.0
        var anyReporting = false
        var unreported: [ServiceType] = []
        for provider in reads.keys.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let providerWrites = writes[provider] ?? 0
            if providerWrites > 0, authoritative[provider] == true {
                anyReporting = true
                reportingReads += reads[provider] ?? 0
                reportingWrites += providerWrites
            } else if (reads[provider] ?? 0) > 0 {
                unreported.append(provider)
            }
        }
        let cacheUse = anyReporting
            ? OptimizationInsights.CacheUse(readTokens: reportingReads, writeTokens: reportingWrites)
            : nil
        return (cacheUse, unreported)
    }

    // MARK: Trend

    /// The last week's daily rate against the whole window's. Only meaningful
    /// when the window is longer than the recent slice *and* the cache covers all
    /// of it: five days of history is not a 30-day average.
    private static func trend(
        rows: [DailyTokenUsage],
        calendar: Calendar,
        today: Date,
        windowDays: Int,
        coveredDays: Int,
        total: Double
    ) -> OptimizationInsights.Trend? {
        guard windowDays > trendRecentDays, coveredDays >= windowDays, total > 0 else { return nil }
        let recentStart = CalendarDayStep.day(today, offsetBy: -(trendRecentDays - 1), calendar: calendar)
        let recent = rows
            .filter { $0.day(on: calendar) >= recentStart }
            .reduce(0) { $0 + TokenComposition($1).total }
        return OptimizationInsights.Trend(
            recentDailyTokens: recent / Double(trendRecentDays),
            windowDailyTokens: total / Double(windowDays),
            recentDays: trendRecentDays
        )
    }

    // MARK: Notes

    nonisolated private struct NoteContext {
        let windowDays: Int
        let coveredDays: Int
        let hasOriginData: Bool
        let originsCoverWindow: Bool
        let unreportedCacheProviders: [ServiceType]
        let compressedCodexRollouts: Int
        let tableNotes: [UsageDataNote]
    }

    private static func dataNotes(
        summary: CostSummary,
        rows: [DailyTokenUsage],
        context: NoteContext
    ) -> [UsageDataNote] {
        let windowDays = context.windowDays
        let coveredDays = context.coveredDays
        let compressedCodexRollouts = context.compressedCodexRollouts
        var notes: [UsageDataNote] = []

        if compressedCodexRollouts > 0 {
            let plural = compressedCodexRollouts == 1 ? "rollout" : "rollouts"
            notes.append(UsageDataNote(
                id: "compressed-rollouts",
                severity: .warning,
                text: "\(compressedCodexRollouts) compressed Codex \(plural) in the scan window "
                    + "aren't counted — MeterBar reads .jsonl logs only."
            ))
        }

        if summary.localScanCompletion == .incomplete {
            notes.append(UsageDataNote(
                id: "scan-incomplete",
                severity: .warning,
                text: "The last scan didn't finish, so recent totals may be short."
            ))
        }

        if coveredDays < windowDays {
            notes.append(UsageDataNote(
                id: "coverage",
                severity: .info,
                text: "Cached history covers \(coveredDays) of \(windowDays) days. "
                    + "Earlier days are gaps, not zero usage."
            ))
        }

        notes.append(contentsOf: context.tableNotes)

        if context.hasOriginData, !context.originsCoverWindow {
            notes.append(UsageDataNote(
                id: "origin-scan-period",
                severity: .info,
                text: "Origins are a \(summary.periodDays)-day scan total; "
                    + "the daily history has no origin split to narrow them."
            ))
        }

        if !context.unreportedCacheProviders.isEmpty {
            let names = context.unreportedCacheProviders.map(\.displayName).formatted(.list(type: .and))
            notes.append(UsageDataNote(
                id: "cache-writes-unreported",
                severity: .info,
                text: "\(names) logs report cache reads but not cache writes, "
                    + "so cache reuse isn't computed for them."
            ))
        }

        if rows.contains(where: { $0.provider == .grok }) {
            notes.append(UsageDataNote(
                id: "grok-reported-cost",
                severity: .info,
                text: "Grok cost is the amount the CLI reported, not an API-rate estimate."
            ))
        }

        let provenance = summary.pricing.flatMap { $0.isEmpty ? nil : $0 } ?? ModelPricing.tableProvenance
        var pricingText = "\(provenance.label). Local logs are priced at API token rates, "
            + "so subscription plans can be compared, not billed."
        if let diagnostic = provenance.diagnosticNote {
            pricingText += " \(diagnostic)"
        }
        notes.append(UsageDataNote(
            id: "pricing",
            severity: provenance.diagnosticNote == nil ? .info : .warning,
            text: pricingText
        ))

        return notes
    }
}
