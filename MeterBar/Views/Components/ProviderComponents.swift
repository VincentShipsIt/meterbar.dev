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

    static func forService(_ service: ServiceType) -> ProviderLogoKind {
        switch service {
        case .codexCli:
            return .codex
        case .claudeCode:
            return .claude
        case .cursor:
            return .cursor
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

    private var label: String {
        switch status.state {
        case .on: return "On"
        case .off: return "Off"
        case .unknown: return "Unknown"
        }
    }

    private var color: Color {
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
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.14))
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(color.opacity(0.20), lineWidth: 1)
        }
        .help(tooltip)
    }
}

struct UsageBar: View {
    let usedPercentage: Double
    let accentColor: Color
    let pace: UsagePace?
    let paceContext: PaceLabelContext

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
                        .fill(MeterBarTheme.danger.opacity(0.16))
                        .frame(width: proxy.size.width, height: 7)
                        .offset(y: 4)
                    RoundedRectangle(cornerRadius: 1)
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

                    RoundedRectangle(cornerRadius: 1)
                        .fill(markerColor(for: pace))
                        .frame(width: 2, height: 13)
                        .offset(x: min(max(0, expectedX - 1), max(0, proxy.size.width - 2)), y: 1)
                } else {
                    Rectangle()
                        .fill(accentColor)
                        .frame(width: proxy.size.width * clampedRemainingPercentage / 100, height: 7)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .offset(y: 4)
                }
            }
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
