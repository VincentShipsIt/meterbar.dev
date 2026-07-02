import Foundation

/// Quota status band. Presentation (colors) is defined per target — the app
/// maps these to `MeterBarTheme`, the widget to plain system colors — so this
/// package stays free of SwiftUI.
public enum UsageStatus: Sendable {
    case good
    case warning
    case critical
}

public extension QuotaBand {
    /// Coarse three-level status for surfaces (widget) that only render
    /// good/warning/critical rather than the full four-band scheme.
    var status: UsageStatus {
        switch self {
        case .healthy: return .good
        case .tight: return .warning
        case .critical, .exhausted: return .critical
        }
    }
}
