import MeterBarShared
import SwiftUI

/// The popover's controls, drawn as tiles that match the provider tiles.
///
/// They replace the old footer of glass pills (status dots, Stay Awake,
/// dashboard and refresh), which read as stray buttons under the cards. Stay
/// Awake and provider status are tiles in the grid; refresh and the dashboard
/// are a quiet text line at the very bottom.
struct PopoverControlTiles: View {
    let openStatusDetail: () -> Void
    var hoverStatusDetail: ((Bool) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: MenuBarPopoverGeometry.cardGap) {
            StayAwakeTile()
            ProviderStatusTile(openDetail: openStatusDetail, hoverChanged: hoverStatusDetail)
                .reportPopoverCardFrame(id: PopoverCardID.providerStatus)
        }
    }
}

/// Icon, title and one status line: the shape both control tiles share.
private struct ControlTileLabel: View {
    let systemImage: String
    let title: String
    let detail: String
    let isActive: Bool
    var detailColor: Color = .secondary
    var iconColor: Color = .primary

    var body: some View {
        DashboardTile(padding: .popover) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? Color.white : iconColor)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(isActive ? AnyShapeStyle(MeterBarTheme.appAccent) : AnyShapeStyle(.quaternary))
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(detailColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: MeterBarTheme.Radius.card, style: .continuous))
    }
}

/// One-click Stay Awake as a toggle tile. The filled icon means the user asked
/// for it; the line under it says whether a session is actually being held.
struct StayAwakeTile: View {
    @ObservedObject private var store: StayAwakeSettingsStore
    @ObservedObject private var manager: PowerAssertionManager

    @MainActor
    init(
        store: StayAwakeSettingsStore? = nil,
        manager: PowerAssertionManager? = nil
    ) {
        self.store = store ?? .shared
        self.manager = manager ?? .shared
    }

    var body: some View {
        Button {
            store.setEnabled(!store.isEnabled)
        } label: {
            ControlTileLabel(
                systemImage: store.isEnabled ? "cup.and.heat.waves.fill" : "cup.and.heat.waves",
                title: "Stay awake",
                detail: StayAwakeTileCopy.detail(
                    isEnabled: store.isEnabled,
                    isHeld: manager.isAssertionHeld,
                    provider: manager.activeProvider?.shortName
                ),
                isActive: store.isEnabled,
                detailColor: manager.isAssertionHeld ? MeterBarTheme.warning : .secondary
            )
        }
        .buttonStyle(ProviderCardButtonStyle(cornerRadius: MeterBarTheme.Radius.card))
        .help("Keep the Mac awake while a session has quota")
        .accessibilityLabel("Stay awake")
        .accessibilityValue(
            StayAwakeTileCopy.detail(
                isEnabled: store.isEnabled,
                isHeld: manager.isAssertionHeld,
                provider: manager.activeProvider?.shortName
            )
        )
        .accessibilityAddTraits(store.isEnabled ? .isSelected : [])
    }
}

enum StayAwakeTileCopy {
    static func detail(isEnabled: Bool, isHeld: Bool, provider: String?) -> String {
        if isHeld, let provider { return "Awake · \(provider)" }
        return isEnabled ? "On · waiting for quota" : "Off"
    }
}

/// Provider status pages reduced to one tile. Hover or click opens the full
/// per-provider list beside the popover, as the status dots used to.
struct ProviderStatusTile: View {
    @StateObject private var statusMonitor = ProviderStatusMonitor.shared

    let openDetail: () -> Void
    var hoverChanged: ((Bool) -> Void)?

    private var summary: ProviderStatusTileSummary {
        ProviderStatusTileSummary(
            reports: ServiceType.statusPageServices.compactMap { statusMonitor.reports[$0] },
            expectedCount: ServiceType.statusPageServices.count
        )
    }

    var body: some View {
        Button(action: openDetail) {
            ControlTileLabel(
                systemImage: "waveform.path.ecg",
                title: "Status",
                detail: summary.text,
                isActive: false,
                detailColor: summary.issueCount > 0 ? MeterBarTheme.warning : .secondary,
                iconColor: summary.issueCount > 0 ? MeterBarTheme.warning : MeterBarTheme.success
            )
        }
        .buttonStyle(ProviderCardButtonStyle(cornerRadius: MeterBarTheme.Radius.card))
        .help("Provider status")
        .accessibilityLabel("Provider status")
        .accessibilityValue(summary.text)
        .accessibilityHint("Show provider status details")
        .onHover { hoverChanged?($0) }
        .task { await statusMonitor.refreshAllIfNeeded() }
    }
}

/// "All operational", "Grok degraded", "2 issues", or "3 of 4 checked" while a
/// status page has not answered (a missing page is not a healthy one).
struct ProviderStatusTileSummary: Equatable {
    let text: String
    let issueCount: Int

    init(reports: [ProviderStatusReport], expectedCount: Int? = nil) {
        let issues = reports.filter(\.hasIssue)
        issueCount = issues.count
        if reports.isEmpty {
            text = "Checking…"
        } else if let only = issues.first, issues.count == 1 {
            text = "\(only.displayName) \(only.headline.lowercased())"
        } else if issues.count > 1 {
            text = "\(issues.count) issues"
        } else if let expectedCount, reports.count < expectedCount {
            text = "\(reports.count) of \(expectedCount) checked"
        } else {
            text = "All operational"
        }
    }
}

/// The popover's last line: freshness on the left, refresh and the dashboard
/// as plain text actions on the right. No capsules.
struct PopoverFooterLine: View {
    let updatedAt: Date?
    let isRefreshing: Bool
    let refresh: () -> Void
    let openDashboard: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(
                .periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)
            ) { timeline in
                Text(Self.freshnessText(updatedAt: updatedAt, isRefreshing: isRefreshing, now: timeline.date))
            }
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button(action: refresh) {
                RefreshingIcon(isRefreshing: isRefreshing)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(isRefreshing ? "Refreshing usage" : "Refresh usage (⌘R)")
            .accessibilityLabel("Refresh")
            .accessibilityValue(isRefreshing ? "Refreshing" : "")
            .meterBarRefreshShortcut()
            .disabled(isRefreshing)

            Button("Open dashboard", action: openDashboard)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open Usage Dashboard")
        }
        .font(.caption)
        .lineLimit(1)
    }

    static func freshnessText(updatedAt: Date?, isRefreshing: Bool, now: Date) -> String {
        if isRefreshing { return "Refreshing…" }
        guard let updatedAt else { return "Not updated yet" }
        return "Updated \(UsageFormat.relative(updatedAt, to: now))"
    }
}
