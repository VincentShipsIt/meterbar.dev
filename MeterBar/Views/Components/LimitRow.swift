import SwiftUI
import MeterBarShared

/// One quota window's worth of UI — title, optional "Estimated" tag, trailing
/// percent/currency value, `UsageBar`, and a footer (pace + reset countdown).
///
/// Replaces three hand-maintained copies that had quietly drifted:
/// `PopoverLimitRow` (popover), `MenuBarProviderLimitDetailRow` (detail panel),
/// and `DashboardLimitRow` (dashboard/settings). `density` selects the
/// spacing/typography treatment for each surface so the single implementation
/// can't diverge again. All display logic lives in the pure `Content` value
/// type so it can be unit-tested without hosting the view.
struct LimitRow: View {
    /// Per-surface sizing. `.compact` = popover provider card (terse, reset-only
    /// footer), `.detail` = menu-bar detail panel (self-carded rows), `.regular`
    /// = dashboard & settings (largest type).
    enum Density {
        case compact
        case detail
        case regular
    }

    let limit: SnapshotLimit
    let accentColor: Color
    var density: Density = .regular

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    private var content: RowContent { RowContent(limit: limit) }

    var body: some View {
        core
            .modifier(CardSurface(enabled: density.hasCardSurface))
    }

    private var core: some View {
        VStack(alignment: .leading, spacing: density.rowSpacing) {
            header
            UsageBar(
                usedPercentage: limit.usedPercent,
                accentColor: accentColor,
                pace: content.pace,
                paceContext: limit.paceContext
            )
            footer
        }
    }

    private var header: some View {
        HStack(spacing: density.headerSpacing) {
            Text(limit.title)
                .font(density.titleFont)
                .fontWeight(density.titleWeight)
                .foregroundColor(density.titleColor)
                .lineLimit(1)

            if content.showsEstimatedTag {
                estimatedTag
            }

            Spacer(minLength: 4)

            Text(content.trailingText)
                .font(density.trailingFont)
                .fontWeight(density.trailingWeight)
                .foregroundColor(content.isTrailingDanger ? MeterBarTheme.danger : .primary)
                .lineLimit(1)
                .numericRefreshTransition(value: content.trailingText, reduceMotion: reduceMotion)
        }
    }

    /// The 8pt fixed-size tag is preserved on the terse surfaces for now; a
    /// follow-up accessibility chip will replace the fixed size. Kept behind
    /// the density so all three surfaces render it through one code path.
    private var estimatedTag: some View {
        Text("Estimated")
            .font(density.estimatedFont)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
    }

    @ViewBuilder private var footer: some View {
        switch density.footerStyle {
        case .resetOnly:
            if content.showsReset {
                ResetCountdownLabel(
                    title: limit.title,
                    limit: limit.usageLimit,
                    font: density.resetFont,
                    foregroundColor: .secondary,
                    iconSize: density.resetIconSize
                )
            }
        case .full:
            HStack(spacing: density.footerSpacing) {
                Text(content.usedText)
                    .font(density.footerFont)
                    .foregroundColor(.secondary)
                    .numericRefreshTransition(value: content.usedText, reduceMotion: reduceMotion)

                if let pace = content.pace {
                    Text(pace.leftLabel)
                        .font(density.footerFont)
                        .foregroundColor(Self.paceLabelColor(pace))
                }

                Spacer(minLength: 6)

                if content.showsReset {
                    ResetCountdownLabel(
                        title: nil,
                        limit: limit.usageLimit,
                        font: density.resetFont,
                        foregroundColor: .secondary,
                        iconSize: density.resetIconSize
                    )
                }
            }
        }
    }

    /// Pace "left" label color, formerly duplicated verbatim in the detail and
    /// dashboard rows.
    static func paceLabelColor(_ pace: UsagePace) -> Color {
        if pace.isExhausted {
            return MeterBarTheme.danger
        }
        switch pace.stage {
        case .reserve:
            return MeterBarTheme.success
        case .deficit:
            return MeterBarTheme.warning
        case .onPace:
            return .secondary
        }
    }
}

extension LimitRow {
    /// Pure display logic for a limit row — no SwiftUI, so every branch (Out vs
    /// percent-left, estimated suppression, currency formatting, reset presence)
    /// is directly testable.
    struct RowContent {
        let limit: SnapshotLimit

        private var isEstimated: Bool { limit.usageLimit.isEstimated }
        private var isOut: Bool { limit.percentLeft <= 0 }

        var showsEstimatedTag: Bool { isEstimated }

        /// Suppressed for estimated limits so a derived total can't drive the
        /// pace overlay on the bar.
        var pace: UsagePace? {
            isEstimated ? nil : limit.usageLimit.pace()
        }

        var showsReset: Bool { limit.usageLimit.resetTime != nil }

        /// Right-of-title value. Currency limits show money remaining; quota
        /// limits show "Out" only for a real (non-estimated) exhaustion,
        /// otherwise the percent-left label.
        var trailingText: String {
            switch limit.valueStyle {
            case .currency:
                let remaining = max(0, limit.usageLimit.total - limit.usageLimit.used)
                return "\(UsageFormat.cost(remaining)) left"
            case .quota:
                return (isOut && !isEstimated) ? "Out" : limit.usageLimit.percentLeftText
            }
        }

        /// The trailing value turns red once the window is exhausted, matching
        /// the pre-unification per-surface behavior.
        var isTrailingDanger: Bool { isOut }

        /// Footer "used" value. Currency limits show money spent; quota limits
        /// show percent-used.
        var usedText: String {
            switch limit.valueStyle {
            case .currency:
                return "\(UsageFormat.cost(limit.usageLimit.used)) spent"
            case .quota:
                return limit.usageLimit.usedPercentageText
            }
        }
    }
}

private extension LimitRow {
    /// Optionally wraps the detail-panel row in its own card surface. The
    /// popover and dashboard rows sit inside a parent tile, so only `.detail`
    /// carries its own surface.
    struct CardSurface: ViewModifier {
        let enabled: Bool

        func body(content: Content) -> some View {
            if enabled {
                content
                    .padding(10)
                    .meterBarCardSurface(cornerRadius: 10)
            } else {
                content
            }
        }
    }
}

// MARK: - Density metrics

private extension LimitRow.Density {
    enum FooterStyle {
        /// Popover: a single reset-countdown line (titled), no pace/used text.
        case resetOnly
        /// Detail + dashboard: used value, pace label, and an untitled reset.
        case full
    }

    var rowSpacing: CGFloat {
        switch self {
        case .compact: return 4
        case .detail, .regular: return 6
        }
    }

    var headerSpacing: CGFloat {
        switch self {
        case .compact: return 4
        case .detail, .regular: return 8
        }
    }

    var titleFont: Font {
        switch self {
        case .compact: return .caption2
        case .detail: return .caption
        case .regular: return .subheadline
        }
    }

    var titleWeight: Font.Weight {
        switch self {
        case .compact: return .regular
        case .detail: return .semibold
        case .regular: return .bold
        }
    }

    var titleColor: Color {
        switch self {
        case .compact: return .secondary
        case .detail, .regular: return .primary
        }
    }

    /// Fixed 8pt on the terse surfaces (preserved for now); the roomier
    /// dashboard keeps its scalable caption2.
    var estimatedFont: Font {
        switch self {
        case .compact, .detail: return .system(size: 8)
        case .regular: return .caption2
        }
    }

    var trailingFont: Font {
        switch self {
        case .compact, .detail: return .caption
        case .regular: return .subheadline
        }
    }

    var trailingWeight: Font.Weight {
        switch self {
        case .compact, .detail: return .semibold
        case .regular: return .bold
        }
    }

    var footerStyle: FooterStyle {
        switch self {
        case .compact: return .resetOnly
        case .detail, .regular: return .full
        }
    }

    var footerFont: Font {
        switch self {
        case .detail: return .caption2
        case .regular: return .caption
        case .compact: return .caption2
        }
    }

    var footerSpacing: CGFloat {
        switch self {
        case .detail: return 6
        case .regular: return 8
        case .compact: return 6
        }
    }

    var resetFont: Font {
        switch self {
        case .compact, .detail: return .caption2
        case .regular: return .caption
        }
    }

    var resetIconSize: CGFloat {
        switch self {
        case .compact, .detail: return 9
        case .regular: return 10
        }
    }

    var hasCardSurface: Bool {
        self == .detail
    }
}
