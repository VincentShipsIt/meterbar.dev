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
            return nil
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

    private var tooltipText: String? {
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
                    let expectedRemainingPercent = max(0, 100 - min(max(pace.expectedUsedPercent, 0), 100))
                    let expectedX = proxy.size.width * expectedRemainingPercent / 100
                    let actualX = proxy.size.width * clampedRemainingPercentage / 100

                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(accentColor)
                            .frame(width: actualX, height: 7)

                        if pace.stage == .deficit {
                            Rectangle()
                                .fill(MeterBarTheme.danger.opacity(0.86))
                                .frame(width: max(0, expectedX - actualX), height: 7)
                                .offset(x: actualX)
                        }
                    }
                    .clipShape(Capsule())
                    .offset(y: 4)

                    RoundedRectangle(cornerRadius: MeterBarTheme.Radius.small)
                        .fill(markerColor(for: pace))
                        .frame(width: 2, height: 13)
                        .offset(x: min(max(0, expectedX - 1), max(0, proxy.size.width - 2)), y: 1)
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
}
