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
    /// Per-surface sizing only — no surface chrome, since every caller already
    /// draws the card the row sits in. `.compact` = popover provider card (terse,
    /// reset-only footer), `.detail` = menu-bar detail panel (same chrome as the
    /// card, fuller footer), `.regular` = dashboard & settings (largest type).
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

    /// The combined VoiceOver label/value applied to the row's single
    /// accessibility element. Sourced from the shared `SnapshotLimit` helpers and
    /// deliberately density-independent — the popover, detail panel, and
    /// dashboard must all speak an identical reading. Exposed so tests can assert
    /// the wiring per density without a rendered-view accessibility harness.
    var accessibilityLabelText: String { limit.localizedAccessibilityLabel }
    var accessibilityValueText: String { limit.localizedAccessibilityValue }

    // Every surface that draws a `LimitRow` already sits inside a card, so the
    // row never draws one of its own. The detail panel used to, which is exactly
    // what made hovering a provider card look like a different design.
    var body: some View {
        VStack(alignment: .leading, spacing: density.rowSpacing) {
            header
            if content.showsUsageBar {
                UsageBar(
                    usedPercentage: limit.usedPercent,
                    accentColor: accentColor,
                    pace: content.pace,
                    paceContext: limit.paceContext
                )
            }
            if content.showsFooter {
                footer
            }
        }
        // One combined VoiceOver element per limit row across all three
        // surfaces, via the shared SnapshotLimit accessibility helpers.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityValue(accessibilityValueText)
    }

    private var header: some View {
        HStack(spacing: density.headerSpacing) {
            Text(limit.localizedTitle)
                .font(density.titleFont)
                .fontWeight(content.emphasizesCompactOutHeader ? .semibold : density.titleWeight)
                .foregroundColor(content.emphasizesCompactOutHeader ? MeterBarTheme.danger : density.titleColor)
                .lineLimit(1)

            if content.showsEstimatedTag {
                estimatedTag
            }

            Spacer(minLength: 4)

            if content.emphasizesCompactOutHeader {
                MeterBarChip(
                    content.trailingText.uppercased(),
                    tint: MeterBarTheme.danger,
                    style: .flat
                )
            } else {
                Text(content.trailingText)
                    .font(density.trailingFont)
                    .fontWeight(density.trailingWeight)
                    .foregroundColor(content.isTrailingDanger ? MeterBarTheme.danger : .primary)
                    .lineLimit(1)
                    .numericRefreshTransition(value: content.trailingText, reduceMotion: reduceMotion)
            }
        }
    }

    /// The "Estimated" tag scales with Dynamic Type on every surface (semantic
    /// `caption2`, no fixed point size), so the smallest label still respects the
    /// user's text-size setting. Kept behind the density so all three surfaces
    /// render it through one code path.
    private var estimatedTag: some View {
        Text(
            "quota.estimated",
            comment: "Badge on a quota total derived by MeterBar rather than reported by a provider."
        )
            .font(density.estimatedFont)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
    }

    @ViewBuilder private var footer: some View {
        switch density.footerStyle {
        case .resetOnly:
            if content.showsReset {
                ResetCountdownLabel(
                    title: limit.localizedTitle,
                    limit: limit.usageLimit,
                    font: density.resetFont,
                    foregroundColor: .secondary,
                    iconSize: density.resetIconSize,
                    usesPopoverPreference: density == .compact
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

        /// A real exhaustion on a non-blocking pool (e.g. Cursor's Other Models
        /// while Cursor Models still has room). The header keeps the same "Out"
        /// status as other surfaces; the bar and reset footer are dropped so the
        /// row matches the compact blocked-card treatment.
        var compactsWhenOut: Bool { isOut && !isEstimated }

        var showsUsageBar: Bool { !compactsWhenOut }

        /// Active full-density rows keep their used/pace footer even when the
        /// provider does not publish a reset timestamp. Compact density still
        /// renders no footer in that case because its reset-only footer body is
        /// empty.
        var showsFooter: Bool { !compactsWhenOut }

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
                return LocalizedUsageFormat.amountLeft(UsageFormat.cost(remaining))
            case .quota:
                return (isOut && !isEstimated)
                    ? LocalizedUsageFormat.out()
                    : LocalizedUsageFormat.percentLeft(limit.usageLimit)
            }
        }

        /// The trailing value turns red once the window is exhausted, matching
        /// the pre-unification per-surface behavior.
        var isTrailingDanger: Bool { isOut }

        /// Compact-out rows tint the whole header line danger so a one-line row
        /// still scans as exhausted without bringing the bar back.
        var emphasizesCompactOutHeader: Bool { compactsWhenOut }

        /// Footer "used" value. Currency limits show money spent; quota limits
        /// show percent-used.
        var usedText: String {
            switch limit.valueStyle {
            case .currency:
                return LocalizedUsageFormat.amountSpent(UsageFormat.cost(limit.usageLimit.used))
            case .quota:
                return LocalizedUsageFormat.percentUsed(limit.usageLimit)
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

    /// Semantic `caption2` on every surface so the "Estimated" tag scales with
    /// Dynamic Type (previously a fixed 8pt on the terse surfaces, which ignored
    /// the user's text-size setting).
    var estimatedFont: Font {
        .caption2
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
}
