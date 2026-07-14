import SwiftUI
import MeterBarShared

/// Trailing status badges shown beneath a provider's limits:
/// - "N reset(s) available" — banked rate-limit resets (`resetCreditsAvailable`)
/// - "Extra usage" + On/Off pill — paid overage state (`extraUsage`)
///
/// Shared by the single provider card (`ProviderStatusCard`) that renders on the
/// popover, the dashboard Overview, and the Limits page — one component, so the
/// surfaces can't drift (issue #40).
struct ProviderStatusBadges: View {
    enum Style {
        case compact
        case regular
    }

    let resetCreditsAvailable: Int?
    let extraUsage: ExtraUsageStatus?
    let accentColor: Color
    var style: Style = .compact

    /// Convenience initializer from a `ProviderSnapshot`, which already carries
    /// every field these badges need.
    init(snapshot: ProviderSnapshot, style: Style = .compact) {
        self.resetCreditsAvailable = snapshot.resetCreditsAvailable
        self.extraUsage = snapshot.displayedExtraUsage
        self.accentColor = snapshot.accentColor
        self.style = style
    }

    private var showsResetCredits: Bool {
        (resetCreditsAvailable ?? 0) > 0
    }

    private var showsExtraUsage: Bool {
        extraUsage != nil
    }

    /// Whether either badge will render — lets callers skip the surrounding
    /// stack spacing when there's nothing to show (matches the old inline
    /// behavior where absent badges contributed no layout).
    var hasContent: Bool {
        showsResetCredits || showsExtraUsage
    }

    private var iconSize: CGFloat {
        style == .compact ? 9 : 11
    }

    private var textFont: Font {
        style == .compact ? .caption2 : .caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .compact ? 6 : 8) {
            if let resetCount = resetCreditsAvailable, resetCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundColor(accentColor)
                    Text(Self.resetCreditsLabel(resetCount))
                        .font(textFont)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Spacer(minLength: 4)
                }
                .help(
                    "\(Self.resetCreditsLabel(resetCount)) - banked quota resets you can trigger " +
                    "when you hit a rate limit."
                )
            }

            if showsExtraUsage, let extraUsage {
                HStack(spacing: 4) {
                    Image(systemName: "creditcard")
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("Extra usage")
                        .font(textFont)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 4)
                    ExtraUsageStatusPill(status: extraUsage)
                }
            }
        }
    }

    /// "1 reset available" / "N resets available" — the count of banked
    /// rate-limit resets.
    static func resetCreditsLabel(_ count: Int) -> String {
        "\(count) reset\(count == 1 ? "" : "s") available"
    }
}
