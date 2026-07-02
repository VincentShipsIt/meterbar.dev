import Foundation

/// The single source of truth for quota severity and the integer "% left"
/// figure shown across every surface.
///
/// Before this existed the repo had four competing threshold schemes (UI
/// percent-left 10/25, model percent-used 80/100, notifications 90/100, CLI
/// 50/80) and three `percentLeft` implementations with different rounding, so
/// the menu bar, popover, widget, notifications, and CLI could disagree about
/// the same quota at the same moment. Every surface now derives severity from
/// `QuotaBand` and the displayed percentage from `QuotaMath.percentLeft`.
public enum QuotaBand: Equatable, Sendable {
    case healthy
    case tight
    case critical
    case exhausted

    /// Critical when this much (or less) of the quota is left.
    public static let criticalPercentLeft = 10
    /// Tight when this much (or less) of the quota is left.
    public static let tightPercentLeft = 25

    public static func forPercentLeft(_ percentLeft: Int) -> QuotaBand {
        if percentLeft <= 0 { return .exhausted }
        if percentLeft <= criticalPercentLeft { return .critical }
        if percentLeft <= tightPercentLeft { return .tight }
        return .healthy
    }

    public static func forLimit(_ limit: UsageLimit) -> QuotaBand {
        forPercentLeft(QuotaMath.percentLeft(for: limit))
    }

    /// Short status label shown on provider cards ("Out" / "Critical" / …).
    public var shortLabel: String {
        switch self {
        case .healthy: return "Healthy"
        case .tight: return "Tight"
        case .critical: return "Critical"
        case .exhausted: return "Out"
        }
    }

    /// Headline for the overview status hero (popover and dashboard).
    public var overviewTitle: String {
        switch self {
        case .healthy: return "All tracked quotas look healthy"
        case .tight: return "Quota is tight"
        case .critical: return "Quota needs attention"
        case .exhausted: return "Quota exhausted"
        }
    }

    /// Status icon. The red bands get the strong octagon, the amber band the
    /// triangle, so icon severity always agrees with color and copy.
    public var iconName: String {
        switch self {
        case .healthy: return "checkmark.shield.fill"
        case .tight: return "exclamationmark.triangle.fill"
        case .critical, .exhausted: return "exclamationmark.octagon.fill"
        }
    }
}

public enum QuotaMath {
    /// The integer "% left" figure shown to the user.
    ///
    /// Rounds up and floors at 1 so a nearly-exhausted quota reads "1% left"
    /// rather than rounding down to an alarming-but-wrong 0; exactly 0 only
    /// when the quota is truly spent.
    public static func percentLeft(usedPercent: Double) -> Int {
        let remainingPercent = max(0, 100 - usedPercent)
        return remainingPercent == 0 ? 0 : max(1, Int(ceil(remainingPercent)))
    }

    public static func percentLeft(for limit: UsageLimit) -> Int {
        percentLeft(usedPercent: limit.rawPercentage)
    }
}
