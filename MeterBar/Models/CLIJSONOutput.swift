import Foundation
import MeterBarShared

/// A stable, versioned JSON document emitted by the bundled `meterbar` CLI.
nonisolated public protocol CLIJSONDocument: Encodable {}

nonisolated public extension CLIJSONDocument {
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    func jsonString() throws -> String {
        guard let string = String(data: try jsonData(), encoding: .utf8) else {
            throw CLIJSONOutputError.invalidUTF8
        }
        return string
    }
}

nonisolated private enum CLIJSONOutputError: Error {
    case invalidUTF8
}

/// Version 1 contract for `meterbar usage --json`.
nonisolated public struct UsageCLIJSONResponse: CLIJSONDocument {
    public static let currentSchemaVersion = 1

    private let schemaVersion = currentSchemaVersion
    private let providers: [Provider]

    public init(metrics: [ServiceType: UsageMetrics]) {
        providers = metrics
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { Provider(service: $0.key, metrics: $0.value) }
    }

    private struct Provider: Encodable {
        let provider: String
        let displayName: String
        let windows: [Window]
        let extraUsage: ExtraUsage?
        let resetCreditsAvailable: Int?
        let lastUpdated: Date

        init(service: ServiceType, metrics: UsageMetrics) {
            provider = service.cliIdentifier
            displayName = service.displayName
            windows = [
                metrics.sessionLimit.map { Window(kind: "session", limit: $0) },
                metrics.weeklyLimit.map { Window(kind: "weekly", limit: $0) },
                metrics.codeReviewLimit.map { Window(kind: "codeReview", limit: $0) },
            ].compactMap { $0 }
            extraUsage = metrics.extraUsage.map(ExtraUsage.init(status:))
            resetCreditsAvailable = metrics.resetCreditsAvailable
            lastUpdated = metrics.lastUpdated
        }
    }

    private struct Window: Encodable {
        let kind: String
        let used: Double
        let total: Double
        let percentUsed: Double
        let percentLeft: Int
        let resetAt: Date?
        let windowSeconds: TimeInterval?
        let quotaBand: String
        let estimated: Bool

        init(kind: String, limit: UsageLimit) {
            self.kind = kind
            used = limit.used
            total = limit.total
            percentUsed = limit.percentage
            percentLeft = QuotaMath.percentLeft(for: limit)
            resetAt = limit.resetTime
            windowSeconds = limit.windowSeconds
            quotaBand = QuotaBand.forLimit(limit).cliIdentifier
            estimated = limit.isEstimated
        }
    }

    private struct ExtraUsage: Encodable {
        let state: String
        let detail: String?

        init(status: ExtraUsageStatus) {
            state = status.state.rawValue
            detail = status.detail
        }
    }
}

/// Version 1 contract for `meterbar cost --json`, including `--days` windows.
nonisolated public struct CostCLIJSONResponse: CLIJSONDocument {
    public static let currentSchemaVersion = 1

    private let schemaVersion = currentSchemaVersion
    private let lastScannedAt: Date
    private let period: Period
    private let providers: [Provider]
    private let totalCostUSD: Double
    private let totalTokens: Int
    /// Presentation-only conversion of `totalCostUSD` (issue #270). `nil`
    /// unless the caller explicitly supplies `displayCurrency` — the CLI has
    /// no persisted rate of its own; `--currency`/`--rate` are stateless,
    /// per-invocation flags, never a background exchange-rate fetch.
    private let displayCurrency: DisplayCurrencyJSON?
    /// Provenance of the dated rate entries the last scan priced with (issue
    /// #339). Additive and optional, so version 1 stays intact: caches written
    /// before dated pricing simply omit the key.
    private let pricing: PricingJSON?

    public init(
        cache: CostSummaryCache,
        days: Int? = nil,
        monthToDate: Bool = false,
        displayCurrency: DisplayCurrency? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        lastScannedAt = cache.lastScanDate

        // `monthToDate` takes precedence over `--days`; the CLI's `validate()`
        // rejects passing both, so this ordering only matters for direct callers.
        if monthToDate {
            // Cache v2's daily rows carry model and sanitized project
            // attribution, so the window and all of its breakdowns share the
            // same calendar boundary.
            let window = cache.summary.monthToDateCostWindow(now: now, calendar: calendar)
            period = Period(
                requestedDays: window.requestedDays,
                coveredDays: window.coveredDays,
                isTruncated: window.isTruncated,
                kind: "monthToDate"
            )
            providers = window.providers.map(Provider.init(total:))
            totalCostUSD = window.totalCostUSD
            totalTokens = window.totalTokens
        } else if let days {
            let window = cache.summary.dailyCostWindow(lastDays: days, now: now, calendar: calendar)
            period = Period(
                requestedDays: window.requestedDays,
                coveredDays: window.coveredDays,
                isTruncated: window.isTruncated,
                kind: "days"
            )
            providers = window.providers.map(Provider.init(total:))
            totalCostUSD = window.totalCostUSD
            totalTokens = window.totalTokens
        } else {
            period = Period(
                requestedDays: cache.summary.periodDays,
                coveredDays: cache.summary.periodDays,
                isTruncated: false,
                kind: nil
            )
            providers = cache.summary.costs
                .sorted { $0.provider.sortOrder < $1.provider.sortOrder }
                .map(Provider.init(cost:))
            totalCostUSD = cache.summary.totalCostUSD
            totalTokens = cache.summary.totalTokens
        }

        // Captured into a local first: referencing `self.totalCostUSD` directly
        // inside the closure below would require `self` before every stored
        // property (including `self.displayCurrency` itself) is initialized.
        let finalTotalCostUSD = totalCostUSD
        self.displayCurrency = displayCurrency.map { DisplayCurrencyJSON($0, totalCostUSD: finalTotalCostUSD) }
        pricing = cache.summary.pricing.flatMap(PricingJSON.init(provenance:))
    }

    private struct PricingJSON: Encodable {
        /// Verification date of the oldest rate entry this scan priced with.
        let verifiedFrom: String
        /// Verification date of the newest one; equal to `verifiedFrom` when a
        /// single entry priced everything.
        let verifiedThrough: String
        /// Events older than every entry in the table, priced at the oldest
        /// known rate. Non-zero means those figures are an estimate.
        let eventsBeforeFirstEntry: Int

        init?(provenance: PricingProvenance) {
            guard let first = provenance.verificationDates.first,
                  let last = provenance.verificationDates.last else { return nil }
            verifiedFrom = first
            verifiedThrough = last
            eventsBeforeFirstEntry = provenance.eventsBeforeFirstEntry
        }
    }

    private struct Period: Encodable {
        let requestedDays: Int
        let coveredDays: Int
        let isTruncated: Bool
        /// `"days"`, `"monthToDate"`, or omitted for the full lifetime summary
        /// (issue #270). Optional so the unwindowed fixture's JSON shape is
        /// unchanged — `nil` is simply never emitted.
        let kind: String?
    }

    private struct Provider: Encodable {
        let provider: String
        let displayName: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int?
        let cacheReadTokens: Int
        let totalTokens: Int
        let estimatedCostUSD: Double
        let sessionCount: Int?
        /// Top-level per-model rollup. `nil` means the selected cache/window
        /// does not have complete model attribution.
        let modelBreakdowns: [ModelBreakdown]?
        /// Per-project/worktree rollup (issue #270). `nil` — not merely empty —
        /// whenever the selected rows have incomplete project attribution or
        /// the scan found nothing to attribute, so consumers can tell "not
        /// available here" apart from "everything landed in one project".
        let projectBreakdowns: [ProjectBreakdown]?

        init(cost: TokenCost) {
            provider = cost.provider.cliIdentifier
            displayName = cost.provider.displayName
            inputTokens = cost.inputTokens
            outputTokens = cost.outputTokens
            cacheCreationTokens = cost.cacheCreationTokens
            cacheReadTokens = cost.cacheReadTokens
            totalTokens = cost.totalTokens
            estimatedCostUSD = cost.estimatedCostUSD
            sessionCount = cost.sessionCount
            modelBreakdowns = cost.modelBreakdowns.isEmpty
                ? nil
                : cost.modelBreakdowns.map(ModelBreakdown.init)
            projectBreakdowns = cost.projectBreakdowns.isEmpty
                ? nil
                : cost.projectBreakdowns.map(ProjectBreakdown.init)
        }

        init(total: ProviderDailyTotal) {
            provider = total.provider.cliIdentifier
            displayName = total.provider.displayName
            inputTokens = total.inputTokens
            outputTokens = total.outputTokens
            cacheCreationTokens = nil
            cacheReadTokens = total.cacheReadTokens
            totalTokens = total.totalTokens
            estimatedCostUSD = total.estimatedCostUSD
            sessionCount = nil
            modelBreakdowns = total.modelBreakdowns?.map(ModelBreakdown.init)
            projectBreakdowns = total.projectBreakdowns?.map(ProjectBreakdown.init)
        }
    }

    /// Presentation-only currency conversion of `totalCostUSD` (issue #270).
    /// `source` is always `"manual"`: the CLI never persists or fetches a
    /// rate, so every emission is a fresh, explicit `--currency`/`--rate` pair
    /// the caller typed for this one invocation — never a cached snapshot.
    private struct DisplayCurrencyJSON: Encodable {
        let code: String
        let unitsPerUSD: Double
        let enteredAt: Date
        let totalCostConverted: Double
        let source = "manual"

        init(_ currency: DisplayCurrency, totalCostUSD: Double) {
            code = currency.code
            unitsPerUSD = currency.unitsPerUSD
            enteredAt = currency.enteredAt
            totalCostConverted = currency.convert(usd: totalCostUSD)
        }
    }

    /// One project/worktree rollup row, with its own nested per-model slice
    /// (issue #270). A hand-written mapper — like `Provider` above — rather
    /// than encoding `TokenUsageBreakdown` directly, so the CLI JSON surface
    /// stays independent of that type's internal shape.
    private struct ProjectBreakdown: Encodable {
        let name: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        let totalTokens: Int
        let estimatedCostUSD: Double
        let sessionCount: Int
        let modelBreakdowns: [ModelBreakdown]

        init(_ breakdown: TokenUsageBreakdown) {
            name = breakdown.name
            inputTokens = breakdown.inputTokens
            outputTokens = breakdown.outputTokens
            cacheCreationTokens = breakdown.cacheCreationTokens
            cacheReadTokens = breakdown.cacheReadTokens
            totalTokens = breakdown.totalTokens
            estimatedCostUSD = breakdown.estimatedCostUSD
            sessionCount = breakdown.sessionCount
            modelBreakdowns = breakdown.modelBreakdowns.map(ModelBreakdown.init)
        }
    }

    private struct ModelBreakdown: Encodable {
        let name: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        let totalTokens: Int
        let estimatedCostUSD: Double
        let sessionCount: Int

        init(_ breakdown: TokenUsageBreakdown) {
            name = breakdown.name
            inputTokens = breakdown.inputTokens
            outputTokens = breakdown.outputTokens
            cacheCreationTokens = breakdown.cacheCreationTokens
            cacheReadTokens = breakdown.cacheReadTokens
            totalTokens = breakdown.totalTokens
            estimatedCostUSD = breakdown.estimatedCostUSD
            sessionCount = breakdown.sessionCount
        }
    }
}

/// Versioned error envelope used when a JSON command has no cached input.
nonisolated public struct CLIJSONErrorResponse: CLIJSONDocument {
    public static let currentSchemaVersion = 1

    private let schemaVersion = currentSchemaVersion
    private let error: ErrorDetail

    public init(code: String, message: String) {
        error = ErrorDetail(code: code, message: message)
    }

    private struct ErrorDetail: Encodable {
        let code: String
        let message: String
    }
}

/// The stable provider tokens every CLI JSON document uses (`docs/cli-json-schema.md`).
/// Module-internal so `refresh --json` emits the same tokens as `usage --json`
/// rather than a second, drift-prone mapping.
nonisolated extension ServiceType {
    var cliIdentifier: String {
        switch self {
        case .claudeCode: return "claude"
        case .codexCli: return "codex"
        case .cursor: return "cursor"
        case .openRouter: return "openrouter"
        case .grok: return "grok"
        }
    }

    /// The same tokens in documented order, for `--provider` help and error text.
    static var cliIdentifiers: String {
        allCases.sorted { $0.sortOrder < $1.sortOrder }
            .map(\.cliIdentifier)
            .joined(separator: ", ")
    }

    /// Parses a caller-supplied `--provider` value. Tolerant of surrounding
    /// whitespace and casing so shell interpolation doesn't become a usage error.
    static func fromCLIIdentifier(_ raw: String) -> ServiceType? {
        let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCases.first { $0.cliIdentifier == needle }
    }
}

nonisolated extension QuotaBand {
    var cliIdentifier: String {
        switch self {
        case .healthy: return "healthy"
        case .tight: return "tight"
        case .critical: return "critical"
        case .exhausted: return "exhausted"
        }
    }
}
