import AppKit
import SwiftUI
import MeterBarShared

// Shared provider-facing components used by the popover, dashboard, and
// settings. Extracted from MenuBarView.swift, which had accidentally become
// the app's design system.

enum ProviderLogoKind: Equatable {
    case overview
    case codex
    case claude
    case cursor
    case openai
    case openRouter
    case grok

    static func forService(_ service: ServiceType) -> ProviderLogoKind {
        switch service {
        case .codexCli:
            return .codex
        case .claudeCode:
            return .claude
        case .cursor:
            return .cursor
        case .openRouter:
            return .openRouter
        case .grok:
            return .grok
        }
    }

    static func forApiProvider(_ provider: ApiProvider) -> ProviderLogoKind {
        switch provider {
        case .anthropic:
            return .claude
        case .openai:
            return .openai
        }
    }

    var resourceName: String? {
        switch self {
        case .overview:
            return nil
        case .codex:
            return "ProviderIcon-codex"
        case .claude:
            return "ProviderIcon-claude"
        case .cursor:
            return "ProviderIcon-cursor"
        case .openai:
            return "ProviderIcon-openai"
        case .openRouter:
            return nil
        case .grok:
            return "ProviderIcon-grok"
        }
    }

    var fallbackSystemName: String {
        switch self {
        case .overview:
            return "square.grid.2x2"
        case .codex:
            return ServiceType.codexCli.iconName
        case .claude:
            return ServiceType.claudeCode.iconName
        case .cursor:
            return ServiceType.cursor.iconName
        case .openai:
            return "brain"
        case .openRouter:
            return ServiceType.openRouter.iconName
        case .grok:
            return ServiceType.grok.iconName
        }
    }
}

struct ProviderLogoView: View {
    let kind: ProviderLogoKind
    let size: CGFloat
    let foregroundColor: Color

    var body: some View {
        if let resourceName = kind.resourceName,
           let image = ProviderLogoImageCache.image(named: resourceName) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .foregroundColor(foregroundColor)
                .frame(width: size, height: size)
        } else {
            Image(systemName: kind.fallbackSystemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(foregroundColor)
                .frame(width: size, height: size)
        }
    }
}

enum ProviderLogoImageCache {
    private static var cache: [String: NSImage] = [:]

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] {
            return cached
        }

        if let image = NSImage(named: name) ?? bundledSVGImage(named: name) {
            image.isTemplate = true
            cache[name] = image
            return image
        }

        return nil
    }

    private static func bundledSVGImage(named name: String) -> NSImage? {
        let bundle = Bundle.main
        let url = bundle.url(forResource: name, withExtension: "svg") ??
            bundle.url(forResource: name, withExtension: "svg", subdirectory: "Resources")

        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// Colored On/Off chip showing whether paid "extra usage" / overage is enabled for a service.
struct ExtraUsageStatusPill: View {
    let status: ExtraUsageStatus

    // `label`/`color` are the chip's text + tint; kept internal (not private)
    // so the migration test can assert the On/Off/Unknown mapping is preserved.
    var label: String {
        switch status.state {
        case .on: return "On"
        case .off: return "Off"
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch status.state {
        case .on: return MeterBarTheme.warning
        case .off: return MeterBarTheme.success
        case .unknown: return .secondary
        }
    }

    private var tooltip: String {
        switch status.state {
        case .on:
            let base = "Extra usage is ON — overage can be billed beyond your plan."
            return status.detail.map { "\(base)\n\($0)" } ?? base
        case .off:
            return "Extra usage is OFF — usage is capped at your subscription quota."
        case .unknown:
            return "Extra usage state could not be determined."
        }
    }

    var body: some View {
        // Migrated to the shared `MeterBarChip`. The status color now tints the
        // whole chip (leading dot + label) rather than only the dot, matching
        // the other status badges; the On/Off/Unknown semantics are unchanged.
        MeterBarChip(label, systemImage: "circle.fill", tint: color, style: .flat)
            .help(tooltip)
    }
}

struct UsageBar: View {
    let usedPercentage: Double
    let accentColor: Color
    let pace: UsagePace?
    let paceContext: PaceLabelContext

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    /// Curve the fill/marker sweep to their new positions on refresh instead of
    /// teleporting. `nil` under Reduce Motion (via `Motion.resolve`).
    private var fillAnimation: Animation? {
        MeterBarTheme.Motion.resolve(MeterBarTheme.Motion.standardCurve, reduceMotion: reduceMotion)
    }

    private var clampedUsedPercentage: Double {
        min(max(usedPercentage, 0), 100)
    }

    private var clampedRemainingPercentage: Double {
        max(0, 100 - clampedUsedPercentage)
    }

    private var isExhausted: Bool {
        clampedRemainingPercentage <= 0 || pace?.isExhausted == true
    }

    /// Opacity of the deficit / reserve bands. They stay slightly translucent so
    /// the accent reads through and the bar still looks like one bar.
    static let bandOpacity: Double = 0.86
    /// Opacity of the marker casing — enough to separate the core from whatever
    /// it overlays without turning into a hard white/black slab.
    static let markerCasingOpacity: Double = 0.9

    /// The bar's only textual explanation of the overlay: the popover renders
    /// `LimitRow` at `.compact` density, whose footer is reset-only, so the pace
    /// labels never appear next to it. Kept internal (not private) so the tests
    /// can assert both bands are spelled out here.
    var tooltipText: String? {
        guard let pace else {
            return isExhausted ? "Out of quota\nActual: 100% used\nLeft: 0%" : nil
        }

        var lines = [
            pace.leftLabel,
            "Actual: \(Int(clampedUsedPercentage.rounded()))% used",
            "Left: \(Int(clampedRemainingPercentage.rounded()))%",
            "Expected by now: \(Int(pace.expectedUsedPercent.rounded()))% used",
            "Expected left: \(Int(max(0, 100 - pace.expectedUsedPercent).rounded()))%",
            "Colored fill is current quota left."
        ]

        if isExhausted {
            lines.append("Quota is exhausted until the reset window opens.")
        } else if pace.stage == .deficit {
            lines.append("Red is quota you should still have at this pace.")
        } else if pace.stage == .reserve {
            lines.append("Green is quota you have beyond this pace.")
        }

        if let rightLabel = pace.rightLabel(context: paceContext) {
            lines.append(rightLabel)
        }

        return lines.joined(separator: "\n")
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 7)
                    .offset(y: 4)

                if isExhausted {
                    Capsule()
                        .fill(MeterBarTheme.danger.opacity(MeterBarTheme.Fill.subtle))
                        .frame(width: proxy.size.width, height: 7)
                        .offset(y: 4)
                    RoundedRectangle(cornerRadius: MeterBarTheme.Radius.small)
                        .fill(MeterBarTheme.danger)
                        .frame(width: 2, height: 13)
                        .offset(x: max(0, proxy.size.width - 2), y: 1)
                } else if let pace, pace.stage != .onPace {
                    let geometry = BarGeometry(
                        width: proxy.size.width,
                        usedPercentage: usedPercentage,
                        pace: pace
                    )

                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(accentColor)
                            .frame(width: geometry.fillWidth, height: 7)

                        // Both stages get the same band, on opposite sides of the
                        // marker: deficit paints the empty track you should still
                        // have, reserve paints the part of the fill you're ahead
                        // by. Reserve overlays the accent, so its tint is picked
                        // for luminance contrast rather than hue — see
                        // `MeterBarTheme.reserveBand`.
                        if let band = geometry.band {
                            Rectangle()
                                .fill(bandColor(for: band.kind).opacity(Self.bandOpacity))
                                .frame(width: band.width, height: 7)
                                .offset(x: band.x)
                        }
                    }
                    // The band is positioned with `.offset`, which doesn't grow
                    // the stack, so the painted width has to be stated or the
                    // capsule clips a deficit band off the end of the fill.
                    .frame(width: geometry.paintedWidth, alignment: .leading)
                    .clipShape(Capsule())
                    .offset(y: 4)

                    if let markerX = geometry.markerX {
                        // The marker sits inside the fill whenever the user is
                        // ahead of pace, so the colored core alone can vanish
                        // against the accent. A casing on each side gives it an
                        // edge on any background; the core keeps carrying the
                        // green/red meaning.
                        RoundedRectangle(cornerRadius: MeterBarTheme.Radius.small)
                            .fill(MeterBarTheme.paceMarkerCasing.opacity(Self.markerCasingOpacity))
                            .frame(width: BarGeometry.markerWidth, height: 13)
                            .overlay {
                                RoundedRectangle(cornerRadius: MeterBarTheme.Radius.small)
                                    .fill(markerColor(for: pace))
                                    .frame(width: BarGeometry.markerCoreWidth, height: 13)
                            }
                            .offset(x: markerX, y: 1)
                    }
                } else {
                    Rectangle()
                        .fill(accentColor)
                        .frame(width: proxy.size.width * clampedRemainingPercentage / 100, height: 7)
                        .clipShape(RoundedRectangle(cornerRadius: MeterBarTheme.Radius.small))
                        .offset(y: 4)
                }
            }
            // Sweep the fill/marker widths to their new values on refresh. Keyed
            // on every input that moves a bar so all three branches (exhausted /
            // off-pace / default) animate, not just the default fill.
            .animation(fillAnimation, value: clampedRemainingPercentage)
            .animation(fillAnimation, value: pace?.expectedUsedPercent)
            .animation(fillAnimation, value: isExhausted)
        }
        .frame(height: 15)
        .help(tooltipText ?? "")
    }

    private func markerColor(for pace: UsagePace) -> Color {
        switch pace.stage {
        case .onPace:
            return .white.opacity(0.85)
        case .reserve:
            return MeterBarTheme.success
        case .deficit:
            return MeterBarTheme.danger
        }
    }

    private func bandColor(for kind: BarGeometry.Band.Kind) -> Color {
        switch kind {
        case .reserve:
            return MeterBarTheme.reserveBand
        case .deficit:
            return MeterBarTheme.danger
        }
    }
}

extension UsageBar {
    /// Pure layout math for the off-pace bar — no SwiftUI, so every stage is
    /// directly testable (the same reason `LimitRow.RowContent` exists).
    ///
    /// Everything is measured from the left in "quota left" space, because the
    /// colored fill is what's *left*, not what's used: the fill runs from 0 to
    /// `fillWidth`, and the marker sits where the fill would end if usage were
    /// exactly on pace. The two are on opposite sides of each other depending on
    /// the stage, which is what the band spans.
    struct BarGeometry: Equatable {
        /// Full width of the marker including its casing.
        static let markerWidth: CGFloat = 4
        /// Width of the marker's colored (green/red) core.
        static let markerCoreWidth: CGFloat = 2

        struct Band: Equatable {
            enum Kind: Equatable {
                /// Ahead of pace — spans the marker to the fill's edge, over the accent.
                case reserve
                /// Behind pace — spans the fill's edge to the marker, over the empty track.
                case deficit
            }

            let kind: Kind
            let x: CGFloat
            let width: CGFloat
        }

        /// Width of the accent fill: the quota still left.
        let fillWidth: CGFloat
        /// Width of everything painted on the track — the fill plus a deficit
        /// band hanging off its end. The band is drawn with `.offset`, which
        /// doesn't grow a layout, so the stack needs this width explicitly or the
        /// capsule clip cuts the band off entirely.
        let paintedWidth: CGFloat
        /// The off-pace band, or `nil` on pace / with no pace at all.
        let band: Band?
        /// Leading edge of the marker, clamped inside the bar. `nil` when no band.
        let markerX: CGFloat?

        init(width: CGFloat, usedPercentage: Double, pace: UsagePace?) {
            let width = max(0, width)
            let usedPercent = min(max(usedPercentage, 0), 100)
            fillWidth = width * (100 - usedPercent) / 100

            guard let pace, pace.stage != .onPace else {
                paintedWidth = fillWidth
                band = nil
                markerX = nil
                return
            }

            let expectedRemainingPercent = max(0, 100 - min(max(pace.expectedUsedPercent, 0), 100))
            let expectedX = width * expectedRemainingPercent / 100

            switch pace.stage {
            case .deficit:
                // Less left than expected, so the fill stops short of the marker
                // and the band continues the bar out to it.
                band = Band(kind: .deficit, x: fillWidth, width: max(0, expectedX - fillWidth))
            case .reserve:
                // More left than expected, so the fill overshoots the marker and
                // the band covers the overshoot, inside the fill.
                band = Band(kind: .reserve, x: expectedX, width: max(0, fillWidth - expectedX))
            case .onPace:
                band = nil
            }

            paintedWidth = max(fillWidth, (band?.x ?? 0) + (band?.width ?? 0))

            // Center the marker on the expected position, then keep it whole
            // inside the bar so it never hangs off either cap.
            markerX = min(max(0, expectedX - Self.markerWidth / 2), max(0, width - Self.markerWidth))
        }
    }
}
