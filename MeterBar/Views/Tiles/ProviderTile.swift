import MeterBarShared
import SwiftUI

/// One provider drawn as a Control Center style tile.
///
/// The popover's tightest provider gets the wide `.hero` tile; the rest share a
/// two-column grid of `.compact` tiles. Every figure names its direction
/// ("52% left"), the outlook line says what the number means for the week
/// ("Out by Tue 9 AM"), and the full windows, charts and history live in the
/// hover panel. Right-click offers the tile as a desktop widget or a floating
/// tile, next to the card commands the dashboard already had.
struct ProviderTile: View {
    enum Style: Equatable {
        case hero
        case compact
        /// The always-on-top floating panel: one row, ring first.
        case floating
    }

    static let compactMinHeight: CGFloat = 124

    let snapshot: ProviderSnapshot
    let style: Style
    var commands: [ProviderCardCommand] = []
    var onSelect: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    // Explicit: the private environment storage would otherwise lower the
    // memberwise initializer to file-private. `onSelect` stays last so a
    // trailing closure binds to it, as on `ProviderStatusCard`.
    init(
        snapshot: ProviderSnapshot,
        style: Style,
        commands: [ProviderCardCommand] = [],
        onHoverChange: ((Bool) -> Void)? = nil,
        onSelect: (() -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.style = style
        self.commands = commands
        self.onHoverChange = onHoverChange
        self.onSelect = onSelect
    }

    var body: some View {
        TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
            selectable(PopoverTileContent(snapshot: snapshot, now: timeline.date))
        }
        .onHover { onHoverChange?($0) }
        .providerCardContextMenu(commands)
    }

    private var allowsSelection: Bool {
        ProviderCardPresentation.allowsDetailNavigation(hasSelectionHandler: onSelect != nil, snapshot: snapshot)
    }

    @ViewBuilder
    private func selectable(_ content: PopoverTileContent) -> some View {
        if let onSelect, allowsSelection {
            Button(action: onSelect) {
                tile(content)
            }
            .buttonStyle(ProviderCardButtonStyle(cornerRadius: MeterBarTheme.Radius.card))
            .accessibilityHint("Show \(snapshot.title) details")
        } else {
            tile(content)
        }
    }

    private func tile(_ content: PopoverTileContent) -> some View {
        DashboardTile(
            padding: .popover,
            minHeight: style == .compact ? Self.compactMinHeight : nil,
            maxHeight: style == .compact ? .infinity : nil
        ) {
            switch style {
            case .hero: hero(content)
            case .compact: compact(content)
            case .floating: floating(content)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: MeterBarTheme.Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: content))
        .accessibilityValue(Self.accessibilityValue(for: content))
    }

    // MARK: - Styles

    private func hero(_ content: PopoverTileContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                logo(size: 18)
                identity(content, titleFont: .subheadline)
                Spacer(minLength: 6)
                if content.tone == .critical || content.outlookIsShortfall {
                    MeterBarChip("Tightest", tint: toneColor(content.tone), style: .glass)
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 12) {
                figure(content, size: 40, unitSize: 17)
                VStack(alignment: .leading, spacing: 1) {
                    if let outlook = content.outlook {
                        Text(outlook)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(outlookColor(content))
                            .lineLimit(1)
                    }
                    if let detail = Self.supportingLine(for: content) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .layoutPriority(-1)
            }

            if !content.otherWindows.isEmpty {
                HStack(spacing: 6) {
                    ForEach(content.otherWindows.prefix(3)) { chip in
                        windowChip(chip)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func compact(_ content: PopoverTileContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                logo(size: 18)
                Spacer(minLength: 4)
                if let fraction = content.fractionLeft {
                    ring(fraction: fraction, tone: content.tone, diameter: 26, lineWidth: 4)
                }
            }
            figure(content, size: 26, unitSize: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.compactTitle(for: content))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if let window = content.windowTitle {
                    Text(window)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let outlook = content.outlook {
                    Text(outlook)
                        .font(.caption2)
                        .foregroundStyle(content.outlookIsShortfall ? toneColor(.critical) : .secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func floating(_ content: PopoverTileContent) -> some View {
        HStack(spacing: 10) {
            if let fraction = content.fractionLeft {
                ring(fraction: fraction, tone: content.tone, diameter: 30, lineWidth: 4)
            } else {
                logo(size: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                figure(content, size: 20, unitSize: 11)
                Text(Self.compactTitle(for: content))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let outlook = content.outlook {
                    Text(outlook)
                        .font(.caption2)
                        .foregroundStyle(outlookColor(content))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Pieces

    private func logo(size: CGFloat) -> some View {
        ProviderLogoView(kind: snapshot.logoKind, size: size, foregroundColor: snapshot.accentColor)
            .accessibilityHidden(true)
    }

    private func identity(_ content: PopoverTileContent, titleFont: Font) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(content.title)
                .font(titleFont)
                .fontWeight(.semibold)
                .lineLimit(1)
            if let plan = Self.planAndWindow(for: content) {
                Text(plan)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// The figure with its unit set smaller beside it ("52" + "% left"). A
    /// status word or credit balance is drawn whole.
    @ViewBuilder
    private func figure(_ content: PopoverTileContent, size: CGFloat, unitSize: CGFloat) -> some View {
        if let figure = content.figure {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(verbatim: figure.number)
                    .font(.system(size: size, weight: .bold, design: .rounded))
                    .foregroundStyle(content.tone == .critical ? toneColor(.critical) : .primary)
                    .monospacedDigit()
                    .numericRefreshTransition(value: figure.number, reduceMotion: reduceMotion)
                Text(verbatim: figure.unit)
                    .font(.system(size: unitSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        } else {
            Text(content.headline)
                .font(.system(size: max(13, size * 0.55), weight: .semibold, design: .rounded))
                .foregroundStyle(headlineColor(content))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
    }

    private func windowChip(_ chip: PopoverTileContent.WindowChip) -> some View {
        HStack(spacing: 4) {
            Text(chip.title)
                .foregroundStyle(.secondary)
            Text(chip.valueText)
                .fontWeight(.semibold)
                .foregroundStyle(chip.tone == .healthy ? .primary : toneColor(chip.tone))
                .monospacedDigit()
        }
        .font(.caption2)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private func ring(
        fraction: Double,
        tone: PopoverTileContent.Tone,
        diameter: CGFloat,
        lineWidth: CGFloat
    ) -> some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
            if fraction > 0 {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(toneColor(tone), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(
            MeterBarTheme.Motion.resolve(MeterBarTheme.Motion.standardCurve, reduceMotion: reduceMotion),
            value: fraction
        )
        .accessibilityHidden(true)
    }

    private func toneColor(_ tone: PopoverTileContent.Tone) -> Color {
        switch tone {
        case .healthy: snapshot.accentColor
        case .tight: MeterBarTheme.warning
        case .critical: MeterBarTheme.danger
        case .neutral: .secondary
        }
    }

    private func headlineColor(_ content: PopoverTileContent) -> Color {
        content.tone == .neutral ? ProviderCardPresentation.statusColor(for: snapshot) : .primary
    }

    private func outlookColor(_ content: PopoverTileContent) -> Color {
        content.outlookIsShortfall ? MeterBarTheme.danger : .secondary
    }

    // MARK: - Copy

    /// "Ultra · Weekly": the plan when known, then the window the figure is for.
    static func planAndWindow(for content: PopoverTileContent) -> String? {
        let parts = [content.planLabel, content.windowTitle].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Codex · Pro", or just the provider when no plan is reported.
    static func compactTitle(for content: PopoverTileContent) -> String {
        guard let plan = content.planLabel, !plan.isEmpty else { return content.title }
        return "\(content.title) · \(plan)"
    }

    /// "48% used" under the hero's outlook, so both readings sit side by side.
    static func supportingLine(for content: PopoverTileContent) -> String? {
        content.usedText
    }

    static func accessibilityLabel(for content: PopoverTileContent) -> String {
        [content.title, content.planLabel, content.windowTitle]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    static func accessibilityValue(for content: PopoverTileContent) -> String {
        [content.headline, content.usedText, content.outlook]
            .compactMap { $0 }
            .joined(separator: ". ")
    }
}
