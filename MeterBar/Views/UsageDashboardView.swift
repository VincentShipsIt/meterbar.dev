import AppKit
import SwiftUI

@MainActor
final class UsageDashboardWindowController {
    static let shared = UsageDashboardWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if window == nil {
            let hostingController = NSHostingController(rootView: UsageDashboardView())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MeterBar Usage"
            window.contentMinSize = NSSize(width: 900, height: 600)
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case limits = "Limits"
    case costs = "Costs"
    case settings = "Settings"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .overview:
            return "gauge.with.dots.needle.bottom.50percent"
        case .limits:
            return "chart.bar.fill"
        case .costs:
            return "dollarsign.circle.fill"
        case .settings:
            return "gearshape.fill"
        }
    }
}

struct UsageDashboardView: View {
    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var costTracker = CostTracker.shared
    @StateObject private var claudeAccountStore = ClaudeCodeAccountStore.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared

    @State private var selectedSection: DashboardSection = .overview

    var body: some View {
        HStack(spacing: 10) {
            sidebar

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    switch selectedSection {
                    case .overview:
                        overviewContent
                    case .limits:
                        limitsContent
                    case .costs:
                        costsContent
                    case .settings:
                        settingsContent
                    }
                }
                .padding(22)
            }
            .background(Color.white.opacity(0.018))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.055), lineWidth: 1)
            }
        }
        .padding(10)
        .background {
            ZStack {
                Color(red: 0.075, green: 0.080, blue: 0.080)
                Rectangle().fill(.ultraThinMaterial).opacity(0.42)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.cyan)
                Text("MeterBar")
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)

            VStack(spacing: 4) {
                ForEach(DashboardSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.iconName)
                                .frame(width: 22)
                            Text(section.rawValue)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .foregroundColor(selectedSection == section ? .white : .secondary)
                        .background(selectedSection == section ? Color.white.opacity(0.10) : Color.clear)
                        .overlay(alignment: .leading) {
                            if selectedSection == section {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.cyan)
                                    .frame(width: 3)
                                    .padding(.vertical, 7)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Text("Local Sources")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if enabledSourceLabels.isEmpty {
                    Text("No sources enabled")
                } else {
                    ForEach(enabledSourceLabels, id: \.self) { label in
                        Label(label, systemImage: "checkmark.circle.fill")
                    }
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .frame(width: 188)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedSection.rawValue)
                    .font(.title)
                    .fontWeight(.semibold)
                Text(sectionSubtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            RefreshIconButton(
                title: "Refresh",
                help: "Refresh usage",
                isDisabled: dataManager.isLoading || costTracker.isScanning
            ) {
                Task {
                    await refreshDashboard()
                }
            }
        }
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardStatusHero(
                title: overviewStatusTitle,
                detail: overviewStatusDetail,
                color: tightestWindowColor
            )

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                ForEach(providerSnapshots) { snapshot in
                    ProviderOverviewStatusCard(snapshot: snapshot)
                }

                CostOverviewStatusCard(
                    summary: visibleCostSummary,
                    isScanning: costTracker.isScanning,
                    formattedTokens: formattedTokenCount(visibleCostSummary?.totalTokens ?? 0)
                )
            }

            DashboardCard(title: "Last 30 Days", trailing: costTracker.isScanning ? "Scanning..." : nil) {
                costScanChart(height: 180, compact: true)
            }
        }
    }

    private var limitsContent: some View {
        DashboardCard(title: "All Quota Windows", trailing: dataManager.isLoading ? "Refreshing..." : nil) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(providerSnapshots) { snapshot in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            ProviderTitle(
                                title: snapshot.title,
                                logoKind: snapshot.logoKind,
                                color: color(for: snapshot.service),
                                font: .title3
                            )
                            Spacer()
                            Text("Updated \(relativeDate(snapshot.lastUpdated))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        ForEach(snapshot.limits) { limit in
                            DashboardLimitRow(limit: limit, accentColor: color(for: snapshot.service))
                        }
                    }

                    if snapshot.id != providerSnapshots.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var costsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardCard(title: "30 Day API-Rate Token Spend", trailing: costTracker.isScanning ? "Scanning..." : nil) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Local subscription logs are estimated using API token rates so Codex and Claude can be compared.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if costTracker.isScanning {
                        costScanChart(height: 220, compact: false)
                    } else if let summary = visibleCostSummary {
                        DailyUsageChart(dailyUsage: summary.dailyUsage)
                            .frame(height: 220)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Run a local scan to load 30-day token history.")
                                .foregroundColor(.secondary)
                            Button {
                                Task {
                                    await costTracker.scanCosts(days: 30)
                                }
                            } label: {
                                HStack(spacing: 7) {
                                    LucideIcon(.search, size: 13, lineWidth: 2.4)
                                    Text("Scan 30 Days")
                                }
                            }
                            .disabled(costTracker.isScanning)
                        }
                        .frame(height: 220, alignment: .center)
                    }

                    Divider()

                    if let summary = visibleCostSummary, !summary.dailyUsage.isEmpty {
                        DailyUsageBreakdownList(dailyUsage: summary.dailyUsage)
                        Divider()
                    }

                    if let summary = visibleCostSummary, !summary.costs.isEmpty {
                        ForEach(summary.costs) { cost in
                            ProviderCostBreakdown(cost: cost)
                        }
                    } else {
                        Text("No enabled provider token logs found yet.")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func costScanChart(height: CGFloat, compact: Bool) -> some View {
        ZStack {
            if let summary = visibleCostSummary, !summary.dailyUsage.isEmpty {
                DailyUsageChart(dailyUsage: summary.dailyUsage)
                    .opacity(costTracker.isScanning ? 0.42 : 1)
            } else if costTracker.isScanning {
                CostScanLoadingChart(compact: compact)
            } else {
                DailyUsageChart(dailyUsage: [])
            }

            if costTracker.isScanning, visibleCostSummary?.dailyUsage.isEmpty == false {
                CostScanProgressBadge(compact: compact)
            }
        }
        .frame(height: height)
    }

    private var settingsContent: some View {
        SettingsView(embeddedInDashboard: true)
            .frame(maxWidth: 760, minHeight: 520, alignment: .leading)
    }

    private var providerSnapshots: [DashboardProviderSnapshot] {
        var snapshots: [DashboardProviderSnapshot] = []

        if providerVisibility.isEnabled(.codexCli), let codex = dataManager.metrics[.codexCli] {
            snapshots.append(DashboardProviderSnapshot(title: "Codex", service: .codexCli, metrics: codex))
        }

        if providerVisibility.isEnabled(.claudeCode) {
            let claudeAccountMetrics = dataManager.claudeCodeAccountMetrics
            if !claudeAccountMetrics.isEmpty {
                for account in claudeAccountStore.accounts {
                    if let metrics = claudeAccountMetrics[account.id] {
                        snapshots.append(DashboardProviderSnapshot(
                            title: account.isDefault && claudeAccountStore.accounts.count == 1 ? "Claude" : account.name,
                            service: .claudeCode,
                            metrics: metrics
                        ))
                    }
                }
            } else if let claude = dataManager.metrics[.claudeCode] {
                snapshots.append(DashboardProviderSnapshot(title: "Claude", service: .claudeCode, metrics: claude))
            }
        }

        if providerVisibility.isEnabled(.cursor), let cursor = dataManager.metrics[.cursor] {
            snapshots.append(DashboardProviderSnapshot(title: "Cursor", service: .cursor, metrics: cursor))
        }

        return snapshots
    }

    private var visibleCostSummary: CostSummary? {
        costTracker.costSummary?.filtered(to: providerVisibility.enabledServices)
    }

    private var enabledSourceLabels: [String] {
        var labels: [String] = []
        if providerVisibility.isEnabled(.codexCli) {
            labels.append("Codex logs")
        }
        if providerVisibility.isEnabled(.claudeCode) {
            labels.append("Claude JSONL")
        }
        if providerVisibility.isEnabled(.cursor) {
            labels.append("Cursor local state")
        }
        if providerVisibility.isEnabled(.claude) || providerVisibility.isEnabled(.openai) {
            labels.append("Quota APIs")
        }
        return labels
    }

    private var tightestWindowColor: Color {
        guard let limit = providerSnapshots.flatMap(\.limits).min(by: { $0.percentLeft < $1.percentLeft }) else {
            return .secondary
        }
        if limit.percentLeft <= 0 { return .red.opacity(0.72) }
        if limit.percentLeft <= 10 { return .red }
        if limit.percentLeft <= 25 { return MeterBarTheme.warning }
        return .green
    }

    private var overviewStatusTitle: String {
        guard !providerSnapshots.isEmpty else { return "No sources enabled" }
        guard let limit = providerSnapshots.flatMap(\.limits).min(by: { $0.percentLeft < $1.percentLeft }) else {
            return "Waiting for usage"
        }
        if limit.percentLeft <= 0 { return "Quota exhausted" }
        if limit.percentLeft <= 10 { return "Quota needs attention" }
        if limit.percentLeft <= 25 { return "Quota is tight" }
        return "All tracked quotas look healthy"
    }

    private var overviewStatusDetail: String {
        guard !providerSnapshots.isEmpty else {
            return "Enable providers in Settings to show quota status."
        }
        guard let limit = providerSnapshots.flatMap(\.limits).min(by: { $0.percentLeft < $1.percentLeft }) else {
            return "Refresh to load enabled provider status."
        }
        if limit.percentLeft <= 0 {
            return "\(limit.title) is out until reset. Tracking \(providerSnapshots.count) local provider sources."
        }
        return "\(limit.title) has \(limit.percentLeft)% left. Tracking \(providerSnapshots.count) local provider sources."
    }

    private var sectionSubtitle: String {
        switch selectedSection {
        case .overview:
            return "Current health and local token history"
        case .limits:
            return "Every tracked quota window"
        case .costs:
            return "Local 30-day token spend"
        case .settings:
            return "Accounts, refresh, and local sources"
        }
    }

    private func refreshDashboard() async {
        if selectedSection == .costs {
            await costTracker.scanCosts(days: 30)
        } else {
            await dataManager.refreshAll()
        }
    }

    private func color(for service: ServiceType) -> Color {
        switch service {
        case .claude, .claudeCode:
            return MeterBarTheme.claudeAccent
        case .codexCli, .openai:
            return .cyan
        case .cursor:
            return .green
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func formattedTokenCount(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

private struct DashboardProviderSnapshot: Identifiable {
    let id: String
    let title: String
    let service: ServiceType
    let logoKind: ProviderLogoKind
    let lastUpdated: Date
    let limits: [DashboardLimit]

    init(title: String, service: ServiceType, metrics: UsageMetrics) {
        self.id = "\(service.rawValue)-\(title)"
        self.title = title
        self.service = service
        self.logoKind = Self.logoKind(for: service)
        self.lastUpdated = metrics.lastUpdated
        self.limits = [
            DashboardLimit(title: "Session", limit: metrics.sessionLimit),
            DashboardLimit(title: "Weekly", limit: metrics.weeklyLimit),
            DashboardLimit(title: service == .codexCli ? "Code Review" : "Sonnet", limit: metrics.codeReviewLimit)
        ].compactMap { $0 }
    }

    var resetWindows: [ResetCountdownWindow] {
        limits.map {
            ResetCountdownWindow(
                id: "\(id)-\($0.title)",
                title: $0.title,
                limit: $0.usageLimit
            )
        }
    }

    private static func logoKind(for service: ServiceType) -> ProviderLogoKind {
        switch service {
        case .codexCli, .openai:
            return .codex
        case .claude, .claudeCode:
            return .claude
        case .cursor:
            return .cursor
        }
    }
}

private struct DashboardLimit: Identifiable {
    let id = UUID()
    let title: String
    let usageLimit: UsageLimit

    init?(title: String, limit: UsageLimit?) {
        guard let limit else { return nil }
        self.title = title
        self.usageLimit = limit
    }

    var usedPercent: Double {
        usageLimit.rawPercentage
    }

    var percentLeft: Int {
        let remainingPercent = max(0, 100 - usedPercent)
        return remainingPercent == 0 ? 0 : max(1, Int(ceil(remainingPercent)))
    }
}

private struct DashboardStatusHero: View {
    let title: String
    let detail: String
    let color: Color

    private var iconName: String {
        if title.localizedCaseInsensitiveContains("exhausted") {
            return "exclamationmark.octagon.fill"
        }
        if title.localizedCaseInsensitiveContains("attention")
            || title.localizedCaseInsensitiveContains("tight") {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.shield.fill"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 46, height: 46)
                Image(systemName: iconName)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundColor(color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .dashboardCardBackground()
    }
}

private struct ProviderOverviewStatusCard: View {
    let snapshot: DashboardProviderSnapshot

    private var accentColor: Color {
        switch snapshot.service {
        case .claude, .claudeCode:
            return MeterBarTheme.claudeAccent
        case .codexCli, .openai:
            return .cyan
        case .cursor:
            return .green
        }
    }

    private var primaryLimit: DashboardLimit? {
        snapshot.limits.min { $0.percentLeft < $1.percentLeft }
    }

    private var statusText: String {
        guard let primaryLimit else { return "No data" }
        if primaryLimit.percentLeft <= 0 { return "Out" }
        if primaryLimit.percentLeft <= 10 { return "Critical" }
        if primaryLimit.percentLeft <= 25 { return "Tight" }
        return "Healthy"
    }

    private var isOut: Bool {
        primaryLimit?.percentLeft ?? 100 <= 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 9) {
                ProviderLogoView(kind: snapshot.logoKind, size: 20, foregroundColor: accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.title)
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text("Updated \(relativeDate(snapshot.lastUpdated))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(statusColor)
            }

            if let primaryLimit {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(primaryLimit.percentLeft)%")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(statusColor)
                    Text("left")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(primaryLimit.title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                UsageBar(
                    usedPercentage: primaryLimit.usedPercent,
                    accentColor: accentColor,
                    pace: primaryLimit.usageLimit.pace(),
                    paceContext: primaryLimit.title.localizedCaseInsensitiveContains("weekly") ? .weekly : .session
                )

                NextResetCountdownLabel(
                    windows: snapshot.resetWindows,
                    font: .caption,
                    foregroundColor: .secondary,
                    iconSize: 11
                )
            }

            VStack(spacing: 7) {
                ForEach(snapshot.limits.prefix(3)) { limit in
                    HStack {
                        Text(limit.title)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(limit.percentLeft <= 0 ? "Out" : "\(limit.percentLeft)% left")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .padding(14)
        .opacity(isOut ? 0.72 : 1)
        .dashboardCardBackground()
    }

    private var statusColor: Color {
        guard let primaryLimit else { return .secondary }
        if primaryLimit.percentLeft <= 0 { return .red.opacity(0.72) }
        if primaryLimit.percentLeft <= 10 { return .red }
        if primaryLimit.percentLeft <= 25 { return MeterBarTheme.warning }
        return .green
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct CostOverviewStatusCard: View {
    let summary: CostSummary?
    let isScanning: Bool
    let formattedTokens: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("API-Rate Estimate")
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text(isScanning ? "Scanning local logs" : "Last 30 days")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            if isScanning {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning...")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.green)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            } else {
                Text(summary?.formattedTotalCost ?? "Scan needed")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            VStack(spacing: 7) {
                HStack {
                    Text("Tokens")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formattedTokens)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                HStack {
                    Text("Providers")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(summary?.costs.count ?? 0)")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
            }
        }
        .padding(14)
        .dashboardCardBackground()
    }
}

private struct DashboardCard<Content: View>: View {
    let title: String
    let trailing: String?
    @ViewBuilder let content: Content

    init(title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.title3)
                    .bold()
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            content
        }
        .padding(14)
        .dashboardCardBackground()
    }
}

private struct ProviderTitle: View {
    let title: String
    let logoKind: ProviderLogoKind
    let color: Color
    let font: Font

    var body: some View {
        HStack(spacing: 8) {
            ProviderLogoView(kind: logoKind, size: 18, foregroundColor: color)
            Text(title)
                .font(font)
                .fontWeight(.semibold)
        }
    }
}

private struct DashboardLimitRow: View {
    let limit: DashboardLimit
    let accentColor: Color

    private var paceContext: PaceLabelContext {
        limit.title.localizedCaseInsensitiveContains("weekly") ? .weekly : .session
    }

    private var isOut: Bool {
        limit.percentLeft <= 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(limit.title)
                    .font(.subheadline)
                    .bold()
                Spacer()
                Text(isOut ? "Out" : "\(limit.percentLeft)% left")
                    .font(.subheadline)
                    .bold()
            }

            UsageBar(
                usedPercentage: limit.usedPercent,
                accentColor: accentColor,
                pace: limit.usageLimit.pace(),
                paceContext: paceContext
            )

            HStack {
                Text("\(Int(limit.usedPercent.rounded()))% used")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let pace = limit.usageLimit.pace() {
                    Text(pace.leftLabel)
                        .font(.caption)
                        .foregroundColor(paceLabelColor(pace))
                }
                Spacer()
                if limit.usageLimit.resetTime != nil {
                    ResetCountdownLabel(
                        title: nil,
                        limit: limit.usageLimit,
                        font: .caption,
                        foregroundColor: .secondary,
                        iconSize: 10
                    )
                }
            }
        }
        .opacity(isOut ? 0.68 : 1)
    }

    private func paceLabelColor(_ pace: UsagePace) -> Color {
        if pace.isExhausted {
            return .red.opacity(0.78)
        }
        switch pace.stage {
        case .reserve:
            return .green
        case .deficit:
            return MeterBarTheme.warning
        case .onPace:
            return .secondary
        }
    }

}

private struct CostScanLoadingChart: View {
    let compact: Bool

    private let barCount = 30

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            GeometryReader { proxy in
                let spacing: CGFloat = compact ? 4 : 5
                let labelHeight: CGFloat = compact ? 34 : 44
                let chartHeight = max(42, proxy.size.height - labelHeight)
                let barWidth = max(4, (proxy.size.width - CGFloat(barCount - 1) * spacing) / CGFloat(barCount))
                let time = timeline.date.timeIntervalSinceReferenceDate
                let sweepWidth = max(42, proxy.size.width * 0.18)
                let sweepX = CGFloat(time.truncatingRemainder(dividingBy: 1.8) / 1.8) * (proxy.size.width + sweepWidth) - sweepWidth

                VStack(alignment: .leading, spacing: compact ? 8 : 11) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning local logs")
                            .font(compact ? .caption : .subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Text("30 days")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    ZStack(alignment: .leading) {
                        HStack(alignment: .bottom, spacing: spacing) {
                            ForEach(0..<barCount, id: \.self) { index in
                                let seed = Double(((index * 17) % 11) + 2) / 13
                                let wave = (sin((time * 3.2) + Double(index) * 0.55) + 1) / 2
                                let height = chartHeight * CGFloat(0.14 + (seed * 0.44) + (wave * 0.28))

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color.cyan.opacity(0.22 + wave * 0.18),
                                                Color.green.opacity(0.18 + seed * 0.25)
                                            ],
                                            startPoint: .bottom,
                                            endPoint: .top
                                        )
                                    )
                                    .frame(width: barWidth, height: max(4, height))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: chartHeight, alignment: .bottomLeading)

                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, Color.white.opacity(0.28), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: sweepWidth, height: chartHeight)
                            .offset(x: sweepX)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                    if !compact {
                        Text("Parsing Claude and Codex sessions")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
    }
}

private struct CostScanProgressBadge: View {
    let compact: Bool

    var body: some View {
        VStack {
            HStack {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(compact ? "Scanning..." : "Updating local scan")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, compact ? 9 : 11)
                .padding(.vertical, compact ? 6 : 8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }

                Spacer()
            }

            Spacer()
        }
        .padding(compact ? 8 : 10)
    }
}

private struct DailyUsageChart: View {
    let dailyUsage: [DailyTokenUsage]
    var daysToShow: Int = 30

    private let barSpacing: CGFloat = 4
    private let labelHeight: CGFloat = 22
    private let legendHeight: CGFloat = 18

    private var days: [DailyUsageDay] {
        let calendar = Calendar.current
        let normalizedDaysToShow = max(1, daysToShow)
        let endDate = calendar.startOfDay(for: Date())
        let startDate = calendar.date(byAdding: .day, value: -(normalizedDaysToShow - 1), to: endDate) ?? endDate
        let grouped = Dictionary(grouping: dailyUsage) { calendar.startOfDay(for: $0.date) }

        return (0..<normalizedDaysToShow).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }

            let rows = grouped[date] ?? []
            let segments = providerOrder.compactMap { provider -> DailyUsageProviderSegment? in
                let providerRows = rows.filter { $0.provider == provider }
                let tokens = providerRows.reduce(0) { $0 + $1.totalTokens }
                guard tokens > 0 else { return nil }

                return DailyUsageProviderSegment(
                    provider: provider,
                    tokens: tokens,
                    cost: providerRows.reduce(0) { $0 + $1.estimatedCostUSD }
                )
            }

            return DailyUsageDay(
                date: date,
                segments: segments,
                cost: rows.reduce(0) { $0 + $1.estimatedCostUSD }
            )
        }
    }

    private var providerOrder: [ServiceType] {
        [.claudeCode, .codexCli, .cursor, .claude, .openai]
    }

    private var visibleProviders: [ServiceType] {
        providerOrder.filter { provider in
            days.contains { day in
                day.segments.contains { $0.provider == provider }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if days.allSatisfy({ $0.totalTokens == 0 }) {
                Text("No token history found for the last 30 days.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                legend

                GeometryReader { proxy in
                    let width = barWidth(totalWidth: proxy.size.width)
                    let chartHeight = max(40, proxy.size.height - labelHeight)

                    VStack(spacing: 5) {
                        HStack(alignment: .bottom, spacing: barSpacing) {
                            ForEach(days) { day in
                                StackedDailyUsageColumn(
                                    day: day,
                                    width: width,
                                    height: barHeight(totalHeight: chartHeight, tokens: day.totalTokens),
                                    maxHeight: chartHeight,
                                    helpText: helpText(for: day),
                                    colorForProvider: color(for:)
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: chartHeight, alignment: .bottomLeading)

                        HStack(alignment: .top, spacing: barSpacing) {
                            ForEach(days.indices, id: \.self) { index in
                                DailyUsageDateLabel(
                                    date: days[index].date,
                                    width: width,
                                    showsMonth: shouldShowMonth(at: index)
                                )
                            }
                        }
                        .frame(height: labelHeight, alignment: .topLeading)
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(visibleProviders, id: \.self) { provider in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: provider))
                        .frame(width: 8, height: 8)
                    Text(provider.displayName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(height: legendHeight, alignment: .leading)
    }

    private var maxTokens: Int {
        max(days.map(\.totalTokens).max() ?? 1, 1)
    }

    private func barWidth(totalWidth: CGFloat) -> CGFloat {
        let gapsWidth = CGFloat(max(0, days.count - 1)) * barSpacing
        return max(4, (totalWidth - gapsWidth) / CGFloat(max(1, days.count)))
    }

    private func barHeight(totalHeight: CGFloat, tokens: Int) -> CGFloat {
        guard tokens > 0 else { return 2 }
        return max(4, totalHeight * CGFloat(tokens) / CGFloat(maxTokens))
    }

    private func shouldShowMonth(at index: Int) -> Bool {
        guard days.indices.contains(index) else { return false }
        if index == 0 { return true }

        return Calendar.current.component(.day, from: days[index].date) == 1
    }

    private func helpText(for day: DailyUsageDay) -> String {
        var lines = [
            fullDateLabel(day.date),
            "\(formatTokens(day.totalTokens)) tokens",
            String(format: "$%.2f", day.cost)
        ]

        if day.segments.isEmpty {
            lines.append("No tracked provider usage")
        } else {
            lines.append("")
            for segment in day.segments {
                lines.append("\(segment.provider.displayName): \(formatTokens(segment.tokens)) · \(String(format: "$%.2f", segment.cost))")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func color(for provider: ServiceType) -> Color {
        switch provider {
        case .claude, .claudeCode:
            return MeterBarTheme.claudeAccent
        case .codexCli, .openai:
            return .cyan
        case .cursor:
            return .green
        }
    }

    private func fullDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

private struct StackedDailyUsageColumn: View {
    let day: DailyUsageDay
    let width: CGFloat
    let height: CGFloat
    let maxHeight: CGFloat
    let helpText: String
    let colorForProvider: (ServiceType) -> Color

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            if day.totalTokens > 0 {
                VStack(spacing: 0) {
                    ForEach(day.segments.reversed()) { segment in
                        Rectangle()
                            .fill(colorForProvider(segment.provider))
                            .frame(height: segmentHeight(segment))
                    }
                }
                .frame(width: width, height: height, alignment: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.10))
                    .frame(width: width, height: 2)
            }
        }
        .frame(width: width, height: maxHeight, alignment: .bottom)
        .help(helpText)
    }

    private func segmentHeight(_ segment: DailyUsageProviderSegment) -> CGFloat {
        guard day.totalTokens > 0 else { return 0 }
        return max(1, height * CGFloat(segment.tokens) / CGFloat(day.totalTokens))
    }
}

private struct DailyUsageDateLabel: View {
    let date: Date
    let width: CGFloat
    let showsMonth: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(dayText)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(showsMonth ? monthText : "")
                .font(.system(size: 7, weight: .medium))
                .foregroundColor(.secondary.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: width, height: 20, alignment: .top)
        .help(fullDateText)
    }

    private var dayText: String {
        String(Calendar.current.component(.day, from: date))
    }

    private var monthText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter.string(from: date)
    }

    private var fullDateText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

private struct DailyUsageDay: Identifiable {
    var id: Date { date }
    let date: Date
    let segments: [DailyUsageProviderSegment]
    let cost: Double

    var totalTokens: Int {
        segments.reduce(0) { $0 + $1.tokens }
    }
}

private struct DailyUsageProviderSegment: Identifiable {
    var id: ServiceType { provider }
    let provider: ServiceType
    let tokens: Int
    let cost: Double
}

private struct DailyUsageBreakdownList: View {
    let dailyUsage: [DailyTokenUsage]

    private var days: [DailyProviderUsageDay] {
        let grouped = Dictionary(grouping: dailyUsage) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.map { day, rows in
            DailyProviderUsageDay(date: day, providers: providerSummaries(from: rows))
        }
        .filter { $0.totalTokens > 0 }
        .sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Daily Details")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                Text("Last 30 days")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(days) { day in
                    DailyUsageDetailRow(day: day)
                }
            }
        }
    }

    private func providerSummaries(from rows: [DailyTokenUsage]) -> [DailyProviderUsageSummary] {
        let grouped = Dictionary(grouping: rows, by: \.provider)
        return grouped.map { provider, providerRows in
            DailyProviderUsageSummary(
                provider: provider,
                inputTokens: providerRows.reduce(0) { $0 + $1.inputTokens },
                outputTokens: providerRows.reduce(0) { $0 + $1.outputTokens },
                cacheReadTokens: providerRows.reduce(0) { $0 + $1.cacheReadTokens },
                estimatedCostUSD: providerRows.reduce(0) { $0 + $1.estimatedCostUSD }
            )
        }
        .sorted { lhs, rhs in
            if lhs.estimatedCostUSD == rhs.estimatedCostUSD {
                return lhs.totalTokens > rhs.totalTokens
            }
            return lhs.estimatedCostUSD > rhs.estimatedCostUSD
        }
    }
}

private struct DailyProviderUsageDay: Identifiable {
    var id: Date { date }
    let date: Date
    let providers: [DailyProviderUsageSummary]

    var totalTokens: Int {
        providers.reduce(0) { $0 + $1.totalTokens }
    }

    var estimatedCostUSD: Double {
        providers.reduce(0) { $0 + $1.estimatedCostUSD }
    }
}

private struct DailyProviderUsageSummary: Identifiable {
    var id: ServiceType { provider }
    let provider: ServiceType
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let estimatedCostUSD: Double

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens
    }
}

private struct DailyUsageDetailRow: View {
    let day: DailyProviderUsageDay

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(dateLabel(day.date))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text(UsageFormat.tokens(day.totalTokens))
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(UsageFormat.cost(day.estimatedCostUSD))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(day.providers) { provider in
                HStack(spacing: 10) {
                    ProviderLogoView(
                        kind: logoKind(for: provider.provider),
                        size: 14,
                        foregroundColor: color(for: provider.provider)
                    )
                    Text(provider.provider.displayName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .frame(width: 110, alignment: .leading)
                    UsageDetailMetric(label: "Input", value: UsageFormat.tokens(provider.inputTokens))
                    UsageDetailMetric(label: "Output", value: UsageFormat.tokens(provider.outputTokens))
                    UsageDetailMetric(label: "Cache", value: UsageFormat.tokens(provider.cacheReadTokens))
                    Spacer()
                    Text(UsageFormat.cost(provider.estimatedCostUSD))
                        .font(.caption)
                        .fontWeight(.semibold)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
    }
}

private struct ProviderCostBreakdown: View {
    let cost: TokenCost

    private var logoKind: ProviderLogoKind {
        switch cost.provider {
        case .codexCli, .openai:
            return .codex
        case .claude, .claudeCode:
            return .claude
        case .cursor:
            return .cursor
        }
    }

    private var logoColor: Color {
        switch cost.provider {
        case .codexCli, .openai:
            return .cyan
        case .claude, .claudeCode:
            return MeterBarTheme.claudeAccent
        case .cursor:
            return .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProviderTitle(
                    title: cost.provider.displayName,
                    logoKind: logoKind,
                    color: logoColor,
                    font: .headline
                )
                Spacer()
                Text(cost.formattedCost)
                    .font(.title3)
                    .bold()
            }

            HStack(spacing: 14) {
                CostMetric(label: "Tokens", value: cost.formattedTokens)
                CostMetric(label: "Input", value: compact(cost.inputTokens))
                CostMetric(label: "Output", value: compact(cost.outputTokens))
                CostMetric(label: "Sessions", value: "\(cost.sessionCount)")
            }

            if !cost.modelBreakdowns.isEmpty {
                CostBreakdownSection(title: "Models", items: cost.modelBreakdowns.prefix(6).map { $0 })
            }

            if !cost.originBreakdowns.isEmpty {
                CostBreakdownSection(title: "Usage Origin", items: cost.originBreakdowns.prefix(6).map { $0 })
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

private struct CostBreakdownSection: View {
    let title: String
    let items: [TokenUsageBreakdown]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            ForEach(items) { item in
                HStack(spacing: 10) {
                    Text(item.name)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .frame(width: 150, alignment: .leading)

                    UsageDetailMetric(label: "Tokens", value: UsageFormat.tokens(item.totalTokens))
                    UsageDetailMetric(label: "Input", value: UsageFormat.tokens(item.inputTokens))
                    UsageDetailMetric(label: "Output", value: UsageFormat.tokens(item.outputTokens))
                    UsageDetailMetric(label: "Cache", value: UsageFormat.tokens(item.cacheReadTokens))

                    Spacer()

                    Text(item.formattedCost)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.top, 4)
    }
}

private struct CostMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageDetailMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(width: 58, alignment: .leading)
    }
}

private enum UsageFormat {
    static func tokens(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    static func cost(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}

private func logoKind(for provider: ServiceType) -> ProviderLogoKind {
    switch provider {
    case .codexCli, .openai:
        return .codex
    case .claude, .claudeCode:
        return .claude
    case .cursor:
        return .cursor
    }
}

private func color(for provider: ServiceType) -> Color {
    switch provider {
    case .claude, .claudeCode:
        return MeterBarTheme.claudeAccent
    case .codexCli, .openai:
        return .cyan
    case .cursor:
        return .green
    }
}

private extension View {
    func dashboardCardBackground() -> some View {
        self
            .background(.thinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
