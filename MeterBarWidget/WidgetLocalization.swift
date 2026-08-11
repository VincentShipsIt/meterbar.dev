import Foundation
import MeterBarShared

/// Target-localized copy derived from the shared widget presentation model.
/// The shared model stays locale-neutral so the app preview and CLI contracts
/// do not accidentally resolve against the widget extension's bundle.
enum WidgetLocalizedContent {
    static func quotaTitle(for row: WidgetPresentationRow) -> String {
        switch (row.service, row.quotaWindow) {
        case (.openRouter, .session):
            return String(localized: "widget.quota.key_limit", defaultValue: "Key limit")
        case (.claudeCode, .codeReview):
            return row.modelLimitLabel
                ?? String(localized: "widget.quota.model", defaultValue: "Model")
        case (_, .codeReview):
            return String(localized: "widget.quota.code_review", defaultValue: "Code Review")
        case (_, .session):
            return String(localized: "widget.quota.session", defaultValue: "Session")
        case (.openRouter, .weekly):
            return String(localized: "widget.quota.account_credits", defaultValue: "Account credits")
        case (.cursor, .weekly):
            return String(localized: "widget.quota.monthly", defaultValue: "Monthly")
        case (_, .weekly):
            return String(localized: "widget.quota.weekly", defaultValue: "Weekly")
        }
    }

    static func summaryText(for row: WidgetPresentationRow) -> String {
        guard let limit = row.limit else {
            return String(localized: "widget.unavailable", defaultValue: "Unavailable")
        }
        if row.service == .openRouter {
            let amount: Double
            switch row.preservesLegacyOpenRouterBalance ? .remaining : row.displayMode {
            case .used:
                amount = max(0, limit.used)
                return LocalizedUsageFormat.amountSpent(ExtraUsageStatus.formatAmount(amount))
            case .remaining:
                amount = max(0, limit.total - limit.used)
                return LocalizedUsageFormat.amountLeft(ExtraUsageStatus.formatAmount(amount))
            }
        }

        switch row.displayMode {
        case .used:
            return LocalizedUsageFormat.percentUsed(limit)
        case .remaining:
            return LocalizedUsageFormat.percentLeft(limit)
        }
    }

    static func compactSummaryText(for row: WidgetPresentationRow) -> String {
        guard row.service == .openRouter,
              row.preservesLegacyOpenRouterBalance,
              let limit = row.limit else {
            return summaryText(for: row)
        }
        return ExtraUsageStatus.formatAmount(max(0, limit.total - limit.used))
    }

    static func accessibilityValue(for row: WidgetPresentationRow, compact: Bool = false) -> String {
        let leading = compact
            ? [compactSummaryText(for: row)]
            : [quotaTitle(for: row), summaryText(for: row)]
        return (leading + [healthDescription(row.health)].compactMap { $0 })
            .formatted(.list(type: .and, width: .short))
    }

    static func healthDescription(_ health: WidgetDataHealth) -> String? {
        switch health {
        case .healthy:
            return nil
        case .stale:
            return String(localized: "widget.health.stale", defaultValue: "Stale usage data")
        case .unavailable:
            return String(localized: "widget.health.unavailable", defaultValue: "Usage unavailable")
        }
    }

    static func emptyTitle(_ state: WidgetPresentationEmptyState) -> String {
        switch state {
        case .noSelection:
            return String(localized: "widget.empty.choose_title", defaultValue: "Choose usage to show")
        case .unavailable:
            return String(localized: "widget.empty.unavailable_title", defaultValue: "Usage unavailable")
        }
    }

    static func emptyDetail(_ state: WidgetPresentationEmptyState) -> String {
        switch state {
        case .noSelection:
            return String(
                localized: "widget.empty.choose_detail",
                defaultValue: "Select accounts and quota windows in MeterBar Settings."
            )
        case .unavailable:
            return String(
                localized: "widget.empty.unavailable_detail",
                defaultValue: "Open MeterBar to refresh provider usage."
            )
        }
    }
}
