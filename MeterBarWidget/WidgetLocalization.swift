import Foundation
import MeterBarShared

/// Target-localized copy derived from the shared widget presentation model.
/// The shared model stays locale-neutral so the app preview and CLI contracts
/// do not accidentally resolve against the widget extension's bundle.
enum WidgetLocalizedContent {
    static func quotaTitle(for row: WidgetPresentationRow) -> String {
        quotaTitle(for: row.quotaTitleKey)
    }

    /// Translates the shared row's already-decided quota title.
    ///
    /// Which title applies — the OpenRouter exceptions, Cursor's included-pool
    /// split, Claude Code's model window — is decided once in
    /// `WidgetPresentationRow.quotaTitleKey`. This switch only supplies the
    /// widget bundle's words for it, so the widget cannot answer a routing
    /// question differently from the app.
    static func quotaTitle(for key: ServiceType.QuotaTitleKey) -> String {
        switch key {
        case .keyLimit:
            return String(localized: "widget.quota.key_limit", defaultValue: "Key limit")
        case let .model(label):
            return label
                ?? String(localized: "widget.quota.model", defaultValue: "Model")
        case .onDemand:
            return String(localized: "widget.quota.on_demand", defaultValue: "On-demand")
        case .codeReview:
            return String(localized: "widget.quota.code_review", defaultValue: "Code Review")
        case .cursorModels:
            return String(localized: "widget.quota.cursor_models", defaultValue: "Cursor Models")
        case .session:
            return String(localized: "widget.quota.session", defaultValue: "Session")
        case .accountCredits:
            return String(localized: "widget.quota.account_credits", defaultValue: "Account credits")
        case .otherModels:
            return String(localized: "widget.quota.other_models", defaultValue: "Other Models")
        case .monthly:
            return String(localized: "widget.quota.monthly", defaultValue: "Monthly")
        case .weekly:
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
        LocalizedUsageFormat.widgetEmptyTitle(state)
    }

    static func emptyDetail(_ state: WidgetPresentationEmptyState) -> String {
        LocalizedUsageFormat.widgetEmptyDetail(state)
    }

    static func burnDownCountdownTitle(for row: WidgetBurnDownRow) -> String {
        LocalizedUsageFormat.burnDownCountdownTitle(row.countdownKind)
    }

    static func burnDownStageText(for row: WidgetBurnDownRow) -> String {
        LocalizedUsageFormat.burnDownStageText(
            stage: row.stage,
            health: row.health,
            fallback: row.stageText
        )
    }

    static func burnDownCountdownText(for row: WidgetBurnDownRow) -> String {
        LocalizedUsageFormat.burnDownCountdownText(
            kind: row.countdownKind,
            fallback: row.countdownText
        )
    }

    static func burnDownAccessibilityValue(for row: WidgetBurnDownRow) -> String {
        var phrases = [
            quotaTitle(for: row.row),
            burnDownStageText(for: row),
            "\(burnDownCountdownTitle(for: row)) \(burnDownCountdownText(for: row))",
        ]
        if let health = healthDescription(row.health),
           !phrases.contains(health) {
            phrases.append(health)
        }
        return phrases.joined(separator: ", ")
    }
}
