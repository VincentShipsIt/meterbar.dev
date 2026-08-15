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
        filter: String? = nil
    ) -> [String] {
        var lines = [
            "╭─────────────────────────────────────────╮",
            "│             MeterBar Usage              │",
            "╰─────────────────────────────────────────╯",
            "",
        ]

        // A `--provider` typo used to print the header and nothing else, which
        // reads like "this provider has no quota data". Say what happened, the
        // way `meterbar doctor` already does — and distinguish a typo from a
        // real provider the cache simply has not seen yet.
        guard !metrics.isEmpty else {
            lines.append(CLIProviderFilter.emptyReportMessage(for: filter))
            return lines
        }

        for (service, metric) in metrics.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            lines.append("▸ \(service.displayName)")

            if let session = metric.sessionLimit {
                lines += limitLines(
                    service == .openRouter ? "  Key limit" : "  Session",
                    session,
                    currency: service == .openRouter
                )
            }
            if let weekly = metric.weeklyLimit {
                lines += limitLines(
                    "  \(service.weeklyQuotaTitle)",
                    weekly,
                    currency: service == .openRouter
                )
            }
            if let codeReview = metric.codeReviewLimit {
                let label = service.codeReviewQuotaTitle(modelLimitLabel: metric.modelLimitLabel)
                lines += limitLines("  \(label)", codeReview)
            }
            lines.append("")
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
