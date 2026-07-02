import AppKit
import MeterBarShared
import SwiftUI

enum ProviderLogoKind: Equatable {
    case overview
    case codex
    case claude
    case cursor

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
        }
    }
}

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
                    metrics: dataManager.metrics,
                    claudeAccounts: claudeAccountStore.accounts,
                    claudeAccountMetrics: dataManager.claudeCodeAccountMetrics,
                    claudeCodeHasAccess: claudeCodeService.hasAccess,
                    codexCliHasAccess: codexCliService.hasAccess,
                    cursorHasAccess: cursorService.hasAccess,
                    enabledServices: providerVisibility.enabledServices,
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

// MARK: - Reusable Components

struct PopoverOverviewPanel: View {
    let metrics: [ServiceType: UsageMetrics]
    let claudeAccounts: [ClaudeCodeAccount]
    let claudeAccountMetrics: [UUID: UsageMetrics]
    let claudeCodeHasAccess: Bool
    let codexCliHasAccess: Bool
    let cursorHasAccess: Bool
    let enabledServices: Set<ServiceType>
    let openDashboard: () -> Void

    private var snapshots: [PopoverProviderSnapshot] {
        var result: [PopoverProviderSnapshot] = []

        if isEnabled(.codexCli) {
            result.append(PopoverProviderSnapshot(
                title: "Codex",
                logoKind: .codex,
                accentColor: MeterBarTheme.codexAccent,
                metrics: metrics[.codexCli],
                emptyDetail: codexCliHasAccess ? "Waiting for refresh" : "Run codex login"
            ))
        }

        if isEnabled(.claudeCode) {
            let accountMetrics = claudeAccountMetrics
            if !accountMetrics.isEmpty {
                for account in claudeAccounts {
                    let title = account.isDefault && claudeAccounts.count == 1 ? "Claude" : account.name
                    result.append(PopoverProviderSnapshot(
                        title: title,
                        logoKind: .claude,
                        accentColor: MeterBarTheme.claudeAccent,
                        metrics: accountMetrics[account.id],
                        emptyDetail: account.isDefault ? "Waiting for refresh" : "Run claude login",
                        accountID: account.id
                    ))
                }
            } else {
                result.append(PopoverProviderSnapshot(
                    title: "Claude",
                    logoKind: .claude,
                    accentColor: MeterBarTheme.claudeAccent,
                    metrics: metrics[.claudeCode],
                    emptyDetail: claudeCodeHasAccess ? "Waiting for refresh" : "Run claude login"
                ))
            }
        }

        if isEnabled(.cursor) {
            result.append(PopoverProviderSnapshot(
                title: "Cursor",
                logoKind: .cursor,
                accentColor: MeterBarTheme.cursorAccent,
                metrics: metrics[.cursor],
                emptyDetail: cursorHasAccess ? "Waiting for refresh" : "Log in to Cursor"
            ))
        }

        return result
    }

    private func isEnabled(_ service: ServiceType) -> Bool {
        enabledServices.contains(service)
    }

    private var tightestLimit: PopoverLimit? {
        snapshots.compactMap(\.primaryLimit).min { $0.percentLeft < $1.percentLeft }
    }

    private var statusColor: Color {
        guard let tightestLimit else { return .secondary }
        return MeterBarTheme.quotaStatusColor(percentLeft: tightestLimit.percentLeft)
    }

    private var statusTitle: String {
        guard !snapshots.isEmpty else { return "No sources enabled" }
        guard let tightestLimit else { return "Waiting for usage" }
        if tightestLimit.percentLeft <= 0 { return "Quota exhausted" }
        if tightestLimit.percentLeft <= 10 { return "Quota needs attention" }
        if tightestLimit.percentLeft <= 25 { return "Quota is tight" }
        return "All tracked quotas look healthy"
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
        guard let tightestLimit else { return "clock.fill" }
        // Align icon severity with the status color/title bands: the <= 10 "needs
        // attention" band is red (danger), so it gets the strong octagon icon
        // rather than the same triangle used for the orange "tight" band.
        if tightestLimit.percentLeft <= 10 { return "exclamationmark.octagon.fill" }
        if tightestLimit.percentLeft <= 25 { return "exclamationmark.triangle.fill" }
        return "checkmark.shield.fill"
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
    }
}

private struct PopoverProviderSnapshot: Identifiable {
    let id: String
    let title: String
    let logoKind: ProviderLogoKind
    let accentColor: Color
    let updatedAt: Date?
    let limits: [PopoverLimit]
    let emptyDetail: String
    let extraUsage: ExtraUsageStatus?
    let resetCreditsAvailable: Int?

    init(
        title: String,
        logoKind: ProviderLogoKind,
        accentColor: Color,
        metrics: UsageMetrics?,
        emptyDetail: String,
        accountID: UUID? = nil
    ) {
        // Disambiguate by account id so two accounts that share a display name
        // (e.g. both "Work") don't collide on a single Identifiable id, which
        // would corrupt the ForEach that renders the provider cards.
        self.id = "\(title)-\(logoKind)-\(accountID?.uuidString ?? "default")"
        self.title = title
        self.logoKind = logoKind
        self.accentColor = accentColor
        self.updatedAt = metrics?.lastUpdated
        self.emptyDetail = emptyDetail
        self.extraUsage = metrics?.extraUsage
        self.resetCreditsAvailable = metrics?.resetCreditsAvailable
        self.limits = [
            PopoverLimit(title: "Session", limit: metrics?.sessionLimit),
            PopoverLimit(title: "Weekly", limit: metrics?.weeklyLimit),
            PopoverLimit(title: logoKind == .claude ? "Sonnet" : "Code Review", limit: metrics?.codeReviewLimit)
        ].compactMap { $0 }
    }

    var primaryLimit: PopoverLimit? {
        limits.min { $0.percentLeft < $1.percentLeft }
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

    var hasExhaustedLimit: Bool {
        limits.contains { $0.usageLimit.isAtLimit }
    }
}

private struct PopoverLimit: Identifiable {
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

private struct PopoverProviderStatusCard: View {
    let snapshot: PopoverProviderSnapshot

    private var primaryLimit: PopoverLimit? {
        snapshot.primaryLimit
    }

    private var statusColor: Color {
        guard let primaryLimit else { return .secondary }
        return MeterBarTheme.quotaStatusColor(percentLeft: primaryLimit.percentLeft)
    }

    private var statusText: String {
        guard let primaryLimit else { return "Offline" }
        if primaryLimit.percentLeft <= 0 { return "Out" }
        if primaryLimit.percentLeft <= 10 { return "Critical" }
        if primaryLimit.percentLeft <= 25 { return "Tight" }
        return "Healthy"
    }

    private var isOut: Bool {
        guard let primaryLimit else { return false }
        return primaryLimit.percentLeft <= 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                BlockingLimitResetCounter(
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

            if let resetCount = snapshot.resetCreditsAvailable, resetCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(snapshot.accentColor)
                    Text(Self.resetCreditsLabel(resetCount))
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Spacer(minLength: 4)
                }
                .help(
                    "\(Self.resetCreditsLabel(resetCount)) - banked quota resets you can trigger " +
                    "when you hit a rate limit."
                )
            }

            if let extraUsage = snapshot.extraUsage {
                HStack(spacing: 4) {
                    Image(systemName: "creditcard")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("Extra usage")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 4)
                    ExtraUsageStatusPill(status: extraUsage)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .opacity(isOut ? 0.72 : 1)
        .cardSurface()
    }

    /// "1 reset available" / "N resets available" — the count of banked rate-limit resets.
    static func resetCreditsLabel(_ count: Int) -> String {
        "\(count) reset\(count == 1 ? "" : "s") available"
    }

    private var updatedText: String {
        guard let updatedAt = snapshot.updatedAt else { return "No data" }
        return "Updated \(UsageFormat.relative(updatedAt))"
    }
}

private struct PopoverLimitRow: View {
    let limit: PopoverLimit
    let accentColor: Color

    private var isOut: Bool {
        limit.percentLeft <= 0
    }

    private var paceContext: PaceLabelContext {
        limit.title.localizedCaseInsensitiveContains("weekly") ? .weekly : .session
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
                paceContext: paceContext
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

struct ResetCountdownWindow: Identifiable {
    let id: String
    let title: String
    let limit: UsageLimit
}

/// Shared tick schedule for all reset-countdown labels. Anchoring to a fixed
/// reference date (a whole-minute boundary) keeps every label in phase so ticks
/// land on real minute boundaries instead of drifting per-view. A 60s cadence is
/// sufficient since the displayed granularity is minutes.
private enum ResetCountdownSchedule {
    static let anchor = Date(timeIntervalSinceReferenceDate: 0)
    static let interval: TimeInterval = 60
}

struct ResetCountdownLabel: View {
    let title: String?
    let limit: UsageLimit
    var font: Font = .caption
    var foregroundColor: Color = .secondary
    var iconSize: CGFloat = 10

    var body: some View {
        TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
            Group {
                if let text = Self.counterText(title: title, limit: limit, now: timeline.date) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: iconSize, weight: .semibold))
                        Text(text)
                            .font(font)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundColor(foregroundColor)
                    .help(text)
                }
            }
        }
    }

    static func counterText(title: String?, limit: UsageLimit, now: Date) -> String? {
        guard let countdown = limit.resetCountdownText(now: now) else { return nil }
        if countdown == "now" {
            return title.map { "\($0) reset due" } ?? "Reset due"
        }
        return title.map { "\($0) reset in \(countdown)" } ?? "Resets in \(countdown)"
    }
}

struct NextResetCountdownLabel: View {
    let windows: [ResetCountdownWindow]
    var font: Font = .caption
    var foregroundColor: Color = .secondary
    var iconSize: CGFloat = 10

    /// How long after a window's reset time we keep showing "reset due" before
    /// treating the data as stale and hiding the label (until a refresh repopulates
    /// a future reset time). Prevents a perpetual "reset due" when a provider goes offline.
    static let resetDueGracePeriod: TimeInterval = 5 * 60

    var body: some View {
        TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
            Group {
                if let window = Self.selectNextWindow(windows, now: timeline.date),
                   let text = ResetCountdownLabel.counterText(
                       title: window.title,
                       limit: window.limit,
                       now: timeline.date
                   ) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: iconSize, weight: .semibold))
                        Text(text)
                            .font(font)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundColor(foregroundColor)
                    .help(text)
                }
            }
        }
    }

    /// Picks the window each provider card should count down to: the soonest
    /// upcoming reset, or — if every window has already passed — the most recently
    /// due one, but only while it is within `gracePeriod` of now. Beyond that the
    /// data is treated as stale and `nil` is returned so the label hides instead of
    /// showing "reset due" indefinitely.
    static func selectNextWindow(
        _ windows: [ResetCountdownWindow],
        now: Date,
        gracePeriod: TimeInterval = resetDueGracePeriod
    ) -> ResetCountdownWindow? {
        let candidates = windows.compactMap { window -> (window: ResetCountdownWindow, seconds: TimeInterval)? in
            guard let seconds = window.limit.secondsUntilReset(now: now) else { return nil }
            return (window, seconds)
        }

        let futureCandidates = candidates.filter { $0.seconds > 0 }
        if let next = futureCandidates.min(by: { $0.seconds < $1.seconds }) {
            return next.window
        }

        if let mostRecent = candidates.max(by: { $0.seconds < $1.seconds }),
           mostRecent.seconds >= -gracePeriod {
            return mostRecent.window
        }

        return nil
    }
}

struct BlockingLimitResetCounter: View {
    let windows: [ResetCountdownWindow]
    let accentColor: Color

    var body: some View {
        TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
            let blockingWindow = Self.selectBlockingWindow(windows, now: timeline.date)
            let title = Self.titleText(for: blockingWindow, in: windows)
            let counter = Self.counterText(for: blockingWindow, now: timeline.date)
            let detail = Self.detailText(for: blockingWindow, in: windows)

            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "hourglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(accentColor)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text(counter)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .help("\(title) \(counter)")
        }
    }

    /// Selects the exhausted window that actually gates usage — the exhausted
    /// window with the latest known reset time (or the most recently passed one
    /// within the grace period). If any exhausted window has no known reset time,
    /// returns `nil` so the card shows a plain "exhausted" state without an
    /// unreliable countdown rather than guessing.
    static func selectBlockingWindow(
        _ windows: [ResetCountdownWindow],
        now: Date,
        gracePeriod: TimeInterval = NextResetCountdownLabel.resetDueGracePeriod
    ) -> ResetCountdownWindow? {
        let exhaustedWindows = windows.filter { $0.limit.isAtLimit }
        guard !exhaustedWindows.isEmpty else { return nil }

        let candidates = exhaustedWindows.compactMap { window -> (window: ResetCountdownWindow, seconds: TimeInterval)? in
            guard let seconds = window.limit.secondsUntilReset(now: now) else { return nil }
            return (window, seconds)
        }

        guard candidates.count == exhaustedWindows.count else { return nil }

        let futureCandidates = candidates.filter { $0.seconds > 0 }
        if let blocking = futureCandidates.max(by: { $0.seconds < $1.seconds }) {
            return blocking.window
        }

        if let mostRecent = candidates.max(by: { $0.seconds < $1.seconds }),
           mostRecent.seconds >= -gracePeriod {
            return mostRecent.window
        }

        return nil
    }

    static func titleText(for window: ResetCountdownWindow?, in windows: [ResetCountdownWindow]) -> String {
        if let window {
            return "\(window.title) reset"
        }

        let exhaustedCount = windows.filter { $0.limit.isAtLimit }.count
        return exhaustedCount > 1 ? "Limits exhausted" : "Limit exhausted"
    }

    static func counterText(for window: ResetCountdownWindow?, now: Date) -> String {
        guard let window,
              let countdown = window.limit.resetCountdownText(now: now) else {
            return "Reset time unavailable"
        }

        return countdown == "now" ? "due now" : "in \(countdown)"
    }

    static func detailText(for window: ResetCountdownWindow?, in windows: [ResetCountdownWindow]) -> String {
        guard window != nil else {
            return "Usage is unavailable until the reset is reported."
        }

        let exhaustedCount = windows.filter { $0.limit.isAtLimit }.count
        return exhaustedCount > 1
            ? "Usage resumes after exhausted limits reset."
            : "Usage is unavailable until this limit resets."
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
