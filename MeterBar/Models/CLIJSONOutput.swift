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

    public init(
        cache: CostSummaryCache,
        days: Int? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        lastScannedAt = cache.lastScanDate

        if let days {
            let window = cache.summary.dailyCostWindow(lastDays: days, now: now, calendar: calendar)
            period = Period(
                requestedDays: window.requestedDays,
                coveredDays: window.coveredDays,
                isTruncated: window.isTruncated
            )
            providers = window.providers.map(Provider.init(total:))
            totalCostUSD = window.totalCostUSD
            totalTokens = window.totalTokens
        } else {
            period = Period(
                requestedDays: cache.summary.periodDays,
                coveredDays: cache.summary.periodDays,
                isTruncated: false
            )
            providers = cache.summary.costs
                .sorted { $0.provider.sortOrder < $1.provider.sortOrder }
                .map(Provider.init(cost:))
            totalCostUSD = cache.summary.totalCostUSD
            totalTokens = cache.summary.totalTokens
        }
    }

    private struct Period: Encodable {
        let requestedDays: Int
        let coveredDays: Int
        let isTruncated: Bool
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
        }
    }
}

/// Version 1 contract for the persisted, metadata-only Fable session snapshot.
nonisolated public struct FableSessionsCLIJSONResponse: CLIJSONDocument {
    public static let currentSchemaVersion = 1

    private let schemaVersion = currentSchemaVersion
    private let sessions: [Session]

    public init(sessions: [ClaudeFableSession]) {
        self.sessions = ClaudeFableSessionPresentation.normalized(sessions).map(Session.init)
    }

    private struct Session: Encodable {
        let id: String
        let profile: Profile
        let model: String
        let state: String
        let firstObservedAt: Date
        let lastObservedAt: Date

        init(_ session: ClaudeFableSession) {
            id = session.id
            profile = Profile(id: session.accountID, name: session.accountName)
            model = session.model
            state = session.state.rawValue
            firstObservedAt = session.firstObservedAt
            lastObservedAt = session.lastObservedAt
        }
    }

    private struct Profile: Encodable {
        let id: UUID
        let name: String
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
}

nonisolated private extension QuotaBand {
    var cliIdentifier: String {
        switch self {
        case .healthy: return "healthy"
        case .tight: return "tight"
        case .critical: return "critical"
        case .exhausted: return "exhausted"
        }
    }
}
