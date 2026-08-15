import Foundation

/// Bundle-aware, locale-safe formatting for quota UI.
///
/// The existing English `UsageLimit` display properties remain unchanged
/// because the bundled CLI uses them for stable terminal output. App and
/// widget callers opt into this formatter and pass their own resource bundle,
/// allowing both UI targets to own an independent String Catalog without
/// coupling machine-readable CLI contracts to a display locale.
public enum LocalizedUsageFormat {
    public static func percentLeft(
        _ limit: UsageLimit,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        let percent = QuotaMath.percentLeft(for: limit)
        if limit.isEstimated {
            return String(
                localized: "quota.percent_left.estimated",
                defaultValue: "~\(percent)% left",
                bundle: bundle,
                locale: locale,
                comment: "Approximate quota percentage remaining. The variable is a whole-number percentage."
            )
        }
        return String(
            localized: "quota.percent_left",
            defaultValue: "\(percent)% left",
            bundle: bundle,
            locale: locale,
            comment: "Quota percentage remaining. The variable is a whole-number percentage."
        )
    }

    public static func percentUsed(
        _ limit: UsageLimit,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        let percent = Int(limit.percentage.rounded())
        if limit.isEstimated {
            return String(
                localized: "quota.percent_used.estimated",
                defaultValue: "~\(percent)% used",
                bundle: bundle,
                locale: locale,
                comment: "Approximate quota percentage used. The variable is a whole-number percentage."
            )
        }
        return String(
            localized: "quota.percent_used",
            defaultValue: "\(percent)% used",
            bundle: bundle,
            locale: locale,
            comment: "Quota percentage used. The variable is a whole-number percentage."
        )
    }

    public static func amountLeft(
        _ amount: String,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        String(
            localized: "quota.amount_left",
            defaultValue: "\(amount) left",
            bundle: bundle,
            locale: locale,
            comment: "Formatted currency amount remaining."
        )
    }

    public static func amountSpent(
        _ amount: String,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        String(
            localized: "quota.amount_spent",
            defaultValue: "\(amount) spent",
            bundle: bundle,
            locale: locale,
            comment: "Formatted currency amount already spent."
        )
    }

    public static func pairedValue(
        _ primary: String,
        _ secondary: String,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        String(
            localized: "quota.paired_value",
            defaultValue: "\(primary), \(secondary)",
            bundle: bundle,
            locale: locale,
            comment: "VoiceOver quota summary. The first variable is remaining or out; the second is used or spent."
        )
    }

    public static func estimatedLabel(
        _ title: String,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        String(
            localized: "quota.estimated_label",
            defaultValue: "\(title), estimated",
            bundle: bundle,
            locale: locale,
            comment: "VoiceOver quota title. The variable is the quota window name."
        )
    }

    public static func out(bundle: Bundle = .main, locale: Locale = .current) -> String {
        String(
            localized: "quota.out",
            defaultValue: "Out",
            bundle: bundle,
            locale: locale,
            comment: "Quota is exhausted."
        )
    }

    /// Compact, locale-aware countdown with at most two non-zero units.
    /// `DateComponentsFormatter` owns unit grammar/plurals for every locale.
    public static func countdown(
        seconds: TimeInterval,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        let wholeSeconds = max(0, Int(seconds.rounded()))
        guard wholeSeconds >= 60 else {
            return String(
                localized: "duration.less_than_one_minute",
                defaultValue: "<1m",
                bundle: bundle,
                locale: locale,
                comment: "Compact duration shorter than one minute."
            )
        }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        return formatter.string(from: TimeInterval(wholeSeconds)) ?? "<1m"
    }

    public static func moreRows(
        _ count: Int,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        String(
            localized: "count.more_rows",
            defaultValue: "+\(count) more",
            bundle: bundle,
            locale: locale,
            comment: "Widget overflow label. The variable is the hidden row count."
        )
    }

    public static func moreUsageRows(
        _ count: Int,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        String(
            localized: "count.more_usage_rows",
            defaultValue: "\(count) more usage rows",
            bundle: bundle,
            locale: locale,
            comment: "VoiceOver widget overflow label. The variable is the hidden usage-row count."
        )
    }

    public static func burnDownCountdownTitle(
        _ kind: WidgetBurnDownCountdownKind,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        switch kind {
        case .projectedExhaustion:
            return String(
                localized: "burndown.projected_empty",
                defaultValue: "Projected empty in",
                bundle: bundle,
                locale: locale,
                comment: "Burn-down widget heading above a projected exhaustion countdown."
            )
        case .reset:
            return String(
                localized: "burndown.resets_in",
                defaultValue: "Resets in",
                bundle: bundle,
                locale: locale,
                comment: "Burn-down widget heading above a quota-reset countdown."
            )
        case .unavailable:
            return String(
                localized: "burndown.countdown",
                defaultValue: "Countdown",
                bundle: bundle,
                locale: locale,
                comment: "Burn-down widget heading when no countdown target is available."
            )
        }
    }

    public static func burnDownStageText(
        stage: WidgetBurnDownStage,
        health: WidgetDataHealth,
        fallback: String,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        switch health {
        case .stale:
            return String(
                localized: "burndown.stale",
                defaultValue: "Stale data",
                bundle: bundle,
                locale: locale,
                comment: "Burn-down widget stage when the cached snapshot is stale."
            )
        case .unavailable:
            return String(
                localized: "burndown.usage_unavailable",
                defaultValue: "Usage unavailable",
                bundle: bundle,
                locale: locale,
                comment: "Burn-down widget stage when no quota is available."
            )
        case .healthy:
            if stage == .unavailable {
                return String(
                    localized: "burndown.pace_unavailable",
                    defaultValue: "Pace unavailable",
                    bundle: bundle,
                    locale: locale,
                    comment: "Burn-down widget stage when pace cannot be computed from a healthy snapshot."
                )
            }
            return fallback
        }
    }

    /// The countdown value a burn-down row shows, with the "no target" fallback
    /// applied.
    ///
    /// `WidgetBurnDownRow.countdownText` is locale-neutral shared data, so an
    /// unavailable countdown arrives as the English sentinel `"Unavailable"` —
    /// which every renderer then has to recognize before it can translate it.
    /// Owning that check here is what keeps the widget and the Settings preview
    /// from disagreeing about when the fallback applies.
    public static func burnDownCountdownText(
        kind: WidgetBurnDownCountdownKind,
        fallback: String,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        if kind == .unavailable || fallback == "Unavailable" {
            return unavailable(bundle: bundle, locale: locale)
        }
        return fallback
    }

    public static func unavailable(
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        String(
            localized: "widget.unavailable",
            defaultValue: "Unavailable",
            bundle: bundle,
            locale: locale,
            comment: "Generic unavailable placeholder."
        )
    }

    public static func widgetEmptyTitle(
        _ state: WidgetPresentationEmptyState,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        switch state {
        case .noSelection:
            return String(
                localized: "widget.empty.choose_title",
                defaultValue: "Choose usage to show",
                bundle: bundle,
                locale: locale,
                comment: "Widget placeholder heading when nothing has been selected to display."
            )
        case .unavailable:
            return String(
                localized: "widget.empty.unavailable_title",
                defaultValue: "Usage unavailable",
                bundle: bundle,
                locale: locale,
                comment: "Widget placeholder heading when no provider usage could be read."
            )
        }
    }

    public static func widgetEmptyDetail(
        _ state: WidgetPresentationEmptyState,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        switch state {
        case .noSelection:
            return String(
                localized: "widget.empty.choose_detail",
                defaultValue: "Select accounts and quota windows in MeterBar Settings.",
                bundle: bundle,
                locale: locale,
                comment: "Widget placeholder body telling the reader where to choose what the widget shows."
            )
        case .unavailable:
            return String(
                localized: "widget.empty.unavailable_detail",
                defaultValue: "Open MeterBar to refresh provider usage.",
                bundle: bundle,
                locale: locale,
                comment: "Widget placeholder body telling the reader how to refresh unavailable usage."
            )
        }
    }
}
