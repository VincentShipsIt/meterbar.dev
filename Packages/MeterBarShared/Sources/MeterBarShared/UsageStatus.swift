import Foundation

/// Quota status band. Presentation (colors) is defined per target — the app
/// maps these to `MeterBarTheme`, the widget to plain system colors — so this
/// package stays free of SwiftUI.
public enum UsageStatus: Sendable {
    case good
    case warning
    case critical
}
