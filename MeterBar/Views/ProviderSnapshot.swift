import Foundation
import SwiftUI
import MeterBarShared

/// One provider card's worth of display data, shared by the popover and the
/// dashboard. Replaces two near-identical private snapshot/limit type pairs
/// (`PopoverProviderSnapshot`/`PopoverLimit` and `DashboardProviderSnapshot`/
/// `DashboardLimit`) whose duplicated logic had already drifted — the two
/// copies disagreed on the third limit's label rule, and the dashboard's hero
/// icon was re-derived by string-matching rendered title copy.
struct ProviderSnapshot: Identifiable {
    let id: String
    let title: String
    let service: ServiceType
    let updatedAt: Date?
    let limits: [SnapshotLimit]
    let emptyDetail: String
    let extraUsage: ExtraUsageStatus?
    let resetCreditsAvailable: Int?

    var logoKind: ProviderLogoKind { .forService(service) }
    var accentColor: Color { MeterBarTheme.accent(for: service) }

    var displayedExtraUsage: ExtraUsageStatus? {
        ExtraUsageDisplayPolicy.visibleStatus(for: service, status: extraUsage)
    }

    var updatedText: String {
        guard let updatedAt else { return "No data" }
        return "Updated \(UsageFormat.relative(updatedAt))"
    }

    /// Whether the provider has reported metrics at all (drives whether the
    /// dashboard renders a card for it).
    var hasMetrics: Bool { updatedAt != nil }

    /// The limit closest to exhaustion — what the card's status reflects.
    var primaryLimit: SnapshotLimit? {
        limits.min { $0.percentLeft < $1.percentLeft }
    }

    /// Severity band of the primary limit; `nil` when no limits are reported.
    var band: QuotaBand? {
        primaryLimit.map { QuotaBand.forPercentLeft($0.percentLeft) }
    }

    var resetWindows: [ResetCountdownWindow] {
        limits.map {
            ResetCountdownWindow(
                id: "\(id)-\($0.title)",
                title: $0.title,
                limit: $0.usageLimit
            )
        }
    }

    var hasExhaustedLimit: Bool {
        limits.contains { $0.usageLimit.isAtLimit }
    }

    /// Weekly exhaustion blocks the whole subscription even when the shorter
    /// session window still has room. Compact overview cards should prioritize
    /// that reset instead of spending space on the session gauge.
    var hasExhaustedWeeklyLimit: Bool {
        limits.contains { $0.kind == .weekly && $0.usageLimit.isAtLimit }
    }

    /// Detail panels should focus on the limit that is actually blocking use.
    /// When the weekly subscription quota is exhausted, the shorter session
    /// window is no longer actionable, even if it still has room.
    var detailLimits: [SnapshotLimit] {
        guard hasExhaustedWeeklyLimit else { return limits }
        return limits.filter { $0.kind != .session }
    }
}

enum ExtraUsageDisplayPolicy {
    static func visibleStatus(for service: ServiceType, status: ExtraUsageStatus?) -> ExtraUsageStatus? {
        guard let status else { return nil }
        guard service == .claudeCode, status.state == .unknown else {
            return status
        }
        return UserDefaults.standard.bool(forKey: StorageKeys.claudeCodeOAuthFallback) ? status : nil
    }
}

struct SnapshotLimit: Identifiable {
    enum Kind {
        case session
        case weekly
        case codeReview
    }

    let id: String
    let kind: Kind
    let title: String
    let usageLimit: UsageLimit

    var usedPercent: Double {
        usageLimit.rawPercentage
    }

    var percentLeft: Int {
        QuotaMath.percentLeft(for: usageLimit)
    }

    /// Pace copy differs for rolling session windows vs weekly/billing windows.
    /// Derived from the limit's kind, not by string-matching the display title.
    var paceContext: PaceLabelContext {
        kind == .weekly ? .weekly : .session
    }
}

enum ProviderSnapshotBuilder {
    struct Input {
        var metrics: [ServiceType: UsageMetrics]
        var claudeAccounts: [ClaudeCodeAccount]
        var claudeAccountMetrics: [UUID: UsageMetrics]
        var enabledServices: Set<ServiceType>
        var claudeCodeHasAccess: Bool = false
        var codexCliHasAccess: Bool = false
        var cursorHasAccess: Bool = false
    }

    /// Builds the provider cards in display order (Codex, Claude accounts,
    /// Cursor). Providers without metrics are included with an empty-state
    /// detail so the popover can render a "waiting / log in" card; the
    /// dashboard filters those out via `hasMetrics`.
    static func snapshots(_ input: Input) -> [ProviderSnapshot] {
        var result: [ProviderSnapshot] = []

        if input.enabledServices.contains(.codexCli) {
            result.append(snapshot(
                title: "Codex",
                service: .codexCli,
                metrics: input.metrics[.codexCli],
                emptyDetail: input.codexCliHasAccess ? "Waiting for refresh" : "Run codex login"
            ))
        }

        if input.enabledServices.contains(.claudeCode) {
            let accountMetrics = input.claudeAccountMetrics
            if !accountMetrics.isEmpty {
                for account in input.claudeAccounts {
                    let title = account.isDefault && input.claudeAccounts.count == 1 ? "Claude" : account.name
                    result.append(snapshot(
                        title: title,
                        service: .claudeCode,
                        metrics: accountMetrics[account.id],
                        emptyDetail: account.isDefault ? "Waiting for refresh" : "Run claude login",
                        accountID: account.id
                    ))
                }
            } else {
                result.append(snapshot(
                    title: "Claude",
                    service: .claudeCode,
                    metrics: input.metrics[.claudeCode],
                    emptyDetail: input.claudeCodeHasAccess ? "Waiting for refresh" : "Run claude login"
                ))
            }
        }

        if input.enabledServices.contains(.cursor) {
            result.append(snapshot(
                title: "Cursor",
                service: .cursor,
                metrics: input.metrics[.cursor],
                emptyDetail: input.cursorHasAccess ? "Waiting for refresh" : "Log in to Cursor"
            ))
        }

        return result
    }

    static func snapshot(
        title: String,
        service: ServiceType,
        metrics: UsageMetrics?,
        emptyDetail: String,
        accountID: UUID? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            // Disambiguate by account id so two accounts that share a display
            // name (e.g. both "Work") don't collide on a single Identifiable
            // id, which would corrupt the ForEach rendering the cards.
            id: "\(service.rawValue)-\(title)-\(accountID?.uuidString ?? "default")",
            title: title,
            service: service,
            updatedAt: metrics?.lastUpdated,
            limits: limits(for: metrics, service: service),
            emptyDetail: emptyDetail,
            extraUsage: metrics?.extraUsage,
            resetCreditsAvailable: metrics?.resetCreditsAvailable
        )
    }

    static func limits(for metrics: UsageMetrics?, service: ServiceType) -> [SnapshotLimit] {
        guard let metrics else { return [] }

        var result: [SnapshotLimit] = []
        if let session = metrics.sessionLimit {
            result.append(SnapshotLimit(id: "session", kind: .session, title: "Session", usageLimit: session))
        }
        if let weekly = metrics.weeklyLimit {
            result.append(SnapshotLimit(id: "weekly", kind: .weekly, title: "Weekly", usageLimit: weekly))
        }
        if let codeReview = metrics.codeReviewLimit {
            // Claude's third window is the Sonnet-only weekly quota; Codex's is
            // its code-review quota. (The popover and dashboard previously
            // implemented this rule with inverted defaults.)
            let title = service == .claudeCode ? "Sonnet" : "Code Review"
            result.append(SnapshotLimit(id: "codeReview", kind: .codeReview, title: title, usageLimit: codeReview))
        }
        return result
    }
}

extension Array where Element == ProviderSnapshot {
    /// The single tightest quota window across every provider — what the
    /// overview hero and menu-bar summaries report.
    var tightestLimit: SnapshotLimit? {
        flatMap(\.limits).min { $0.percentLeft < $1.percentLeft }
    }
}
