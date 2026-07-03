import AppKit
import SwiftUI
import MeterBarShared

struct MenuBarView: View {
    private let popoverWidth: CGFloat = 390
    private let maxPopoverHeight: CGFloat = 560
    private let minPopoverHeight: CGFloat = 180
    private let chromeHeight: CGFloat = 56

    let onContentSizeChange: (NSSize) -> Void

    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var claudeCodeService = ClaudeCodeLocalService.shared
    @StateObject private var codexCliService = CodexCliLocalService.shared
    @StateObject private var cursorService = CursorLocalService.shared
    @StateObject private var claudeAccountStore = ClaudeCodeAccountStore.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var dockVisibility = DockVisibilityStore.shared

    @State private var contentHeight: CGFloat = 320

    init(onContentSizeChange: @escaping (NSSize) -> Void = { _ in }) {
        self.onContentSizeChange = onContentSizeChange
    }

    var body: some View {
        VStack(spacing: 0) {
            popoverHeader

            Divider()

            ScrollView {
                PopoverOverviewPanel(
                    snapshots: ProviderSnapshotBuilder.snapshots(ProviderSnapshotBuilder.Input(
                        metrics: dataManager.metrics,
                        claudeAccounts: claudeAccountStore.accounts,
                        claudeAccountMetrics: dataManager.claudeCodeAccountMetrics,
                        enabledServices: providerVisibility.enabledServices,
                        claudeCodeHasAccess: claudeCodeService.hasAccess,
                        codexCliHasAccess: codexCliService.hasAccess,
                        cursorHasAccess: cursorService.hasAccess
                    )),
                    openDashboard: openDashboard
                )
                    .padding(10)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: MenuContentHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
            }
            .frame(height: scrollHeight)
        }
        .frame(width: popoverWidth, height: popoverHeight)
        .onAppear {
            notifyContentSize()
        }
        .onPreferenceChange(MenuContentHeightPreferenceKey.self) { height in
            guard height > 0, abs(height - contentHeight) > 1 else { return }
            contentHeight = height
            notifyContentSize(height: height)
        }
    }

    private var scrollHeight: CGFloat {
        min(max(80, contentHeight), maxPopoverHeight - chromeHeight)
    }

    private var popoverHeight: CGFloat {
        min(max(chromeHeight + scrollHeight, minPopoverHeight), maxPopoverHeight)
    }

    private func notifyContentSize(height: CGFloat? = nil) {
        let measuredHeight = height ?? contentHeight
        let targetScrollHeight = min(max(80, measuredHeight), maxPopoverHeight - chromeHeight)
        let targetHeight = min(max(chromeHeight + targetScrollHeight, minPopoverHeight), maxPopoverHeight)
        onContentSizeChange(NSSize(width: popoverWidth, height: targetHeight))
    }

    private var popoverHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MeterBarTheme.appAccent)
                Text("MeterBar")
                    .font(.headline)
                    .fontWeight(.semibold)
            }

            Spacer()

            Button(action: openDashboard) {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Open Usage Dashboard")

            Button {
                Task { await dataManager.refreshAll() }
            } label: {
                RefreshingIcon(isRefreshing: dataManager.isLoading)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help(dataManager.isLoading ? "Refreshing usage" : "Refresh usage")

            optionsMenu
        }
        .font(.body)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Show in Dock", isOn: Binding(
                get: { dockVisibility.showInDock },
                set: { dockVisibility.setShowInDock($0) }
            ))
            Button("Open Usage Dashboard", action: openDashboard)
            Divider()
            Button("Quit MeterBar") {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .controlSize(.small)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More options")
    }

    private func openDashboard() {
        UsageDashboardWindowController.shared.show()
    }
}

// MARK: - Overview panel

struct PopoverOverviewPanel: View {
    let snapshots: [ProviderSnapshot]
    let openDashboard: () -> Void

    @StateObject private var apiUsageStore = ApiUsageStore.shared

    private var tightestLimit: SnapshotLimit? {
        snapshots.tightestLimit
    }

    private var overviewBand: QuotaBand? {
        tightestLimit.map { QuotaBand.forPercentLeft($0.percentLeft) }
    }

    private var statusColor: Color {
        overviewBand?.color ?? .secondary
    }

    private var statusTitle: String {
        guard !snapshots.isEmpty else { return "No sources enabled" }
        guard let overviewBand else { return "Waiting for usage" }
        return overviewBand.overviewTitle
    }

    private var statusDetail: String {
        guard !snapshots.isEmpty else {
            return "Enable a provider in Settings."
        }
        guard let tightestLimit else {
            return "Refresh to load enabled providers."
        }
        if tightestLimit.percentLeft <= 0 {
            return "\(tightestLimit.title) is out until reset across \(sourcesLabel)."
        }
        return "\(tightestLimit.title) has \(tightestLimit.percentLeft)% left across \(sourcesLabel)."
    }

    private var sourcesLabel: String {
        snapshots.count == 1 ? "1 source" : "\(snapshots.count) sources"
    }

    private var statusIconName: String {
        overviewBand?.iconName ?? "clock.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(.quaternary)
                        .frame(width: 34, height: 34)
                    Image(systemName: statusIconName)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .cardSurface()

            VStack(spacing: 8) {
                ForEach(snapshots) { snapshot in
                    PopoverProviderStatusCard(snapshot: snapshot)
                }
            }

            ApiUsageSection(store: apiUsageStore, compact: true)

            Button(action: openDashboard) {
                HStack {
                    Label("Open Usage Dashboard", systemImage: "rectangle.split.2x1")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cardSurface()
        }
        .task {
            await apiUsageStore.refresh()
        }
    }
}

private struct PopoverProviderStatusCard: View {
    let snapshot: ProviderSnapshot

    private var statusColor: Color {
        snapshot.band?.color ?? .secondary
    }

    private var statusText: String {
        snapshot.band?.shortLabel ?? "Offline"
    }

    private var isOut: Bool {
        snapshot.band == .exhausted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: snapshot.hasExhaustedLimit ? 8 : 10) {
            HStack(spacing: 7) {
                ProviderLogoView(kind: snapshot.logoKind, size: 17, foregroundColor: snapshot.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(updatedText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(statusText)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(statusColor)
            }

            if snapshot.limits.isEmpty {
                Text(snapshot.emptyDetail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
            } else if snapshot.hasExhaustedLimit {
                CompactBlockingLimitResetRow(
                    windows: snapshot.resetWindows,
                    accentColor: snapshot.accentColor
                )
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(snapshot.limits) { limit in
                        PopoverLimitRow(limit: limit, accentColor: snapshot.accentColor)
                    }
                }
            }

            let badges = ProviderStatusBadges(snapshot: snapshot, style: .compact)
            if badges.hasContent {
                badges
            }
        }
        .padding(snapshot.hasExhaustedLimit ? 9 : 11)
        .frame(maxWidth: .infinity, minHeight: snapshot.hasExhaustedLimit ? 78 : 124, alignment: .topLeading)
        .opacity(isOut ? 0.72 : 1)
        .cardSurface()
    }

    private var updatedText: String {
        guard let updatedAt = snapshot.updatedAt else { return "No data" }
        return "Updated \(UsageFormat.relative(updatedAt))"
    }
}

private struct PopoverLimitRow: View {
    let limit: SnapshotLimit
    let accentColor: Color

    private var isOut: Bool {
        limit.percentLeft <= 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(limit.title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(isOut ? "Out" : "\(limit.percentLeft)% left")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(isOut ? MeterBarTheme.danger : .primary)
                    .lineLimit(1)
            }

            UsageBar(
                usedPercentage: limit.usedPercent,
                accentColor: accentColor,
                pace: limit.usageLimit.pace(),
                paceContext: limit.paceContext
            )

            if limit.usageLimit.resetTime != nil {
                ResetCountdownLabel(
                    title: limit.title,
                    limit: limit.usageLimit,
                    font: .caption2,
                    foregroundColor: .secondary,
                    iconSize: 9
                )
            }
        }
    }
}

private extension View {
    /// Popover content-card surface. Delegates to the shared `meterBarCardSurface`
    /// so the popover and dashboard cards stay visually identical.
    func cardSurface() -> some View {
        meterBarCardSurface()
    }
}

private struct MenuContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
