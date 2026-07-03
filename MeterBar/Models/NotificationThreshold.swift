import Foundation
import MeterBarShared

/// A user-selectable notification threshold, expressed in terms of the shared
/// `QuotaBand` severities rather than a parallel percentage scale.
///
/// Notifications are decided by mapping each threshold to its `QuotaBand` and
/// comparing against `QuotaBand.forLimit(limit)` — the exact same band math the
/// menu bar, popover, widget, and CLI already use. This keeps a single source of
/// truth for "how full is this quota"; the user only picks *which band* should
/// warn and which should alert.
enum NotificationThreshold: String, CaseIterable, Identifiable, Sendable {
    /// 25% or less remaining.
    case tight
    /// 10% or less remaining.
    case critical
    /// Quota fully spent.
    case exhausted

    var id: String { rawValue }

    /// The shared quota band this threshold corresponds to.
    var band: QuotaBand {
        switch self {
        case .tight: return .tight
        case .critical: return .critical
        case .exhausted: return .exhausted
        }
    }

    /// Human-readable label for the Settings pickers.
    var displayName: String {
        switch self {
        case .tight: return "When quota is tight (25% left)"
        case .critical: return "When quota is critical (10% left)"
        case .exhausted: return "When quota is exhausted"
        }
    }

    /// The choices offered for the "warn me" picker — early-warning bands only.
    static let warningOptions: [NotificationThreshold] = [.tight, .critical]

    /// The choices offered for the "alert me" picker — the more severe bands.
    static let criticalOptions: [NotificationThreshold] = [.critical, .exhausted]
}

/// The pure inputs the notification decision depends on: whether notifications
/// are on at all, and the two configurable band thresholds.
///
/// Defaults preserve the pre-preferences behavior exactly — warn in the
/// `.critical` band (≤10% left ≡ the old ≥90% used) and alert when `.exhausted`.
struct NotificationPreferences: Equatable, Sendable {
    var isEnabled: Bool
    var warningThreshold: NotificationThreshold
    var criticalThreshold: NotificationThreshold

    init(
        isEnabled: Bool = true,
        warningThreshold: NotificationThreshold = .critical,
        criticalThreshold: NotificationThreshold = .exhausted
    ) {
        self.isEnabled = isEnabled
        self.warningThreshold = warningThreshold
        self.criticalThreshold = criticalThreshold
    }

    static let `default` = NotificationPreferences()
}
