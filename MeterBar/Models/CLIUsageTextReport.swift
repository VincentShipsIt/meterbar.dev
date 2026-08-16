import Foundation
import MeterBarShared

/// The human-readable report printed by `meterbar usage` without `--json`.
///
/// Lives here rather than in the executable for the same reason as
/// `CLIProviderFilter`: quota titles are centralized on `ServiceType`, and the
/// only copy the tests could not reach is the copy that drifted — the CLI kept
/// spelling out the code-review label itself and so printed "Code Review" for
/// Cursor's on-demand window.
nonisolated public enum CLIUsageTextReport {
    /// Every line of the report, in print order. Empty strings are blank lines.
    public static func lines(
        for metrics: [ServiceType: UsageMetrics],
        accounts: [AccountUsageSnapshot] = [],
        filter: String? = nil,
        accountFilter: String? = nil
    ) -> [String] {
        lines(for: UsageCLISelection.resolve(
            metrics: metrics,
            accounts: accounts,
            provider: filter,
            account: accountFilter
        ))
    }

    /// Every line of the report, in print order. Empty strings are blank lines.
    public static func lines(for selection: UsageCLISelection) -> [String] {
        var lines = [
            "╭─────────────────────────────────────────╮",
            "│             MeterBar Usage              │",
            "╰─────────────────────────────────────────╯",
            "",
        ]

        // A `--provider` / `--account` typo used to print the header and
        // nothing else, which reads like "this provider has no quota data".
        if let message = selection.emptyReportMessage {
            lines.append(message)
            return lines
        }

        let accountFilterActive = CLIAccountFilter.isActive(selection.accountFilter)
        let accountsByService = Dictionary(grouping: selection.accounts, by: \.metrics.service)

        for service in ServiceType.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let serviceAccounts = accountsByService[service], !serviceAccounts.isEmpty {
                for snapshot in serviceAccounts {
                    lines.append("▸ \(service.displayName) · \(snapshot.name)")
                    lines += metricLines(service, snapshot.metrics)
                    lines.append("")
                }
                continue
            }

            // `--account` is account-scoped: do not fall back to the
            // representative provider row when the account needle missed.
            guard !accountFilterActive, let metric = selection.metrics[service] else { continue }
            lines.append("▸ \(service.displayName)")
            lines += metricLines(service, metric)
            lines.append("")
        }

        return lines
    }

    private static func metricLines(_ service: ServiceType, _ metric: UsageMetrics) -> [String] {
        var lines: [String] = []
        if let session = metric.sessionLimit {
            lines += limitLines(
                "  \(service.sessionQuotaTitle(limitTotal: session.total, periodKind: session.periodKind))",
                session,
                currency: service == .openRouter
            )
        }
        if let weekly = metric.weeklyLimit {
            lines += limitLines(
                "  \(service.weeklyQuotaTitle(limitTotal: weekly.total, periodKind: weekly.periodKind))",
                weekly,
                currency: service == .openRouter
            )
        }
        if let codeReview = metric.codeReviewLimit {
            let label = service.codeReviewQuotaTitle(modelLimitLabel: metric.modelLimitLabel)
            lines += limitLines("  \(label)", codeReview)
        }
        for additional in metric.additionalLimits {
            lines += limitLines(
                "  \(service.additionalQuotaTitleKey(for: additional).englishTitle)",
                additional
            )
        }
        return lines
    }

    private static func limitLines(
        _ label: String,
        _ limit: UsageLimit,
        currency: Bool = false
    ) -> [String] {
        let percent = limit.percentage
        let bar = progressBar(percent: percent, width: 20)
        let status = statusEmoji(for: limit)
        let percentText = currency ? String(format: "%.0f%%", percent) : limit.percentageText

        var lines = ["\(label): \(bar) \(percentText) \(status)"]
        if currency {
            lines.append("    \(UsageFormat.cost(limit.used)) spent / \(UsageFormat.cost(limit.total)) credits")
        } else {
            let estimateDetail = limit.isEstimated ? " (estimated limit)" : ""
            lines.append("    \(Int(limit.used))/\(Int(limit.total)) used\(estimateDetail)")
        }
        if let reset = limit.resetTime {
            lines.append("    Resets: \(UsageFormat.relative(reset))")
        }
        return lines
    }

    private static func progressBar(percent: Double, width: Int) -> String {
        let filled = Int((percent / 100) * Double(width))
        let empty = width - filled
        return "[" + String(repeating: "█", count: filled) + String(repeating: "░", count: empty) + "]"
    }

    /// Same severity bands as the app (previously the CLI warned at 50% used
    /// while the app warned at 75%).
    private static func statusEmoji(for limit: UsageLimit) -> String {
        switch QuotaBand.forLimit(limit) {
        case .healthy: return "✓"
        case .tight: return "⚠"
        case .critical, .exhausted: return "✗"
        }
    }
}
