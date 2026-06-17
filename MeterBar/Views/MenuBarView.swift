import AppKit
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
    private let popoverWidth: CGFloat = 430
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

    @State private var contentHeight: CGFloat = 320

    init(onContentSizeChange: @escaping (NSSize) -> Void = { _ in }) {
        self.onContentSizeChange = onContentSizeChange
    }

    var body: some View {
        VStack(spacing: 0) {
            popoverHeader

            Divider()
                .opacity(0.35)

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
        .background {
            ZStack {
                Color(red: 0.075, green: 0.080, blue: 0.080).opacity(0.74)
                Rectangle().fill(.ultraThinMaterial)
            }
        }
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
                    .foregroundColor(.cyan)
                Text("MeterBar")
                    .font(.headline)
                    .fontWeight(.semibold)
            }

            Spacer()

            Button(action: openDashboard) {
                LucideIcon(.panelRight, size: 17, lineWidth: 2.25)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(MeterBarTheme.toolbarIconForeground)
            .background(MeterBarTheme.toolbarIconBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(MeterBarTheme.toolbarIconBorder, lineWidth: 1)
            }
            .help("Open Usage Dashboard")

            RefreshIconButton(help: "Refresh usage") {
                Task {
                    await dataManager.refreshAll()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
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
                accentColor: .cyan,
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
                        emptyDetail: account.isDefault ? "Waiting for refresh" : "Run claude login"
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
                accentColor: .green,
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
        if tightestLimit.percentLeft <= 0 { return .red.opacity(0.72) }
        if tightestLimit.percentLeft <= 10 { return .red }
        if tightestLimit.percentLeft <= 25 { return MeterBarTheme.warning }
        return .green
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
            return "\(tightestLimit.title) is out until reset across \(snapshots.count) sources."
        }
        return "\(tightestLimit.title) has \(tightestLimit.percentLeft)% left across \(snapshots.count) sources."
    }

    private var statusIconName: String {
        guard let tightestLimit else { return "clock.fill" }
        if tightestLimit.percentLeft <= 0 { return "exclamationmark.octagon.fill" }
        if tightestLimit.percentLeft <= 25 { return "exclamationmark.triangle.fill" }
        return "checkmark.shield.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.20))
                        .frame(width: 34, height: 34)
                    Image(systemName: statusIconName)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(statusColor)
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
            .popoverGlassCard()

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
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
            .popoverGlassCard()
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

    init(
        title: String,
        logoKind: ProviderLogoKind,
        accentColor: Color,
        metrics: UsageMetrics?,
        emptyDetail: String
    ) {
        self.id = "\(title)-\(logoKind)"
        self.title = title
        self.logoKind = logoKind
        self.accentColor = accentColor
        self.updatedAt = metrics?.lastUpdated
        self.emptyDetail = emptyDetail
        self.limits = [
            PopoverLimit(title: "Session", limit: metrics?.sessionLimit),
            PopoverLimit(title: "Weekly", limit: metrics?.weeklyLimit),
            PopoverLimit(title: logoKind == .codex ? "Code Review" : "Sonnet", limit: metrics?.codeReviewLimit)
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
        if primaryLimit.percentLeft <= 0 { return .red.opacity(0.72) }
        if primaryLimit.percentLeft <= 10 { return .red }
        if primaryLimit.percentLeft <= 25 { return MeterBarTheme.warning }
        return .green
    }

    private var statusText: String {
        guard let primaryLimit else { return "Offline" }
        if primaryLimit.percentLeft <= 0 { return "Out" }
        if primaryLimit.percentLeft <= 10 { return "Critical" }
        if primaryLimit.percentLeft <= 25 { return "Tight" }
        return "Healthy"
    }

    private var isOut: Bool {
        primaryLimit?.percentLeft ?? 100 <= 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
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
            }

            if let primaryLimit {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(primaryLimit.percentLeft)%")
                        .font(.system(size: 25, weight: .bold))
                        .foregroundColor(statusColor)
                    Text("left")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Text(primaryLimit.title)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                UsageBar(
                    usedPercentage: primaryLimit.usedPercent,
                    accentColor: snapshot.accentColor,
                    pace: primaryLimit.usageLimit.pace(),
                    paceContext: primaryLimit.title.localizedCaseInsensitiveContains("weekly") ? .weekly : .session
                )

                NextResetCountdownLabel(
                    windows: snapshot.resetWindows,
                    font: .caption2,
                    foregroundColor: .secondary,
                    iconSize: 10
                )

                VStack(spacing: 5) {
                    ForEach(snapshot.limits.prefix(2)) { limit in
                        HStack {
                            Text(limit.title)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(limit.percentLeft <= 0 ? "Out" : "\(limit.percentLeft)%")
                                .font(.caption2)
                                .fontWeight(.semibold)
                        }
                    }
                }
            } else {
                Text(snapshot.emptyDetail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
            }

            Text(statusText)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(statusColor)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
        .opacity(isOut ? 0.72 : 1)
        .popoverGlassCard()
    }

    private var updatedText: String {
        guard let updatedAt = snapshot.updatedAt else { return "No data" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Updated \(formatter.localizedString(for: updatedAt, relativeTo: Date()))"
    }
}

struct ResetCountdownWindow: Identifiable {
    let id: String
    let title: String
    let limit: UsageLimit
}

struct ResetCountdownLabel: View {
    let title: String?
    let limit: UsageLimit
    var font: Font = .caption
    var foregroundColor: Color = .secondary
    var iconSize: CGFloat = 10

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 30)) { timeline in
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

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 30)) { timeline in
            Group {
                if let window = nextWindow(now: timeline.date),
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

    private func nextWindow(now: Date) -> ResetCountdownWindow? {
        let candidates = windows.compactMap { window -> (window: ResetCountdownWindow, seconds: TimeInterval)? in
            guard let seconds = window.limit.secondsUntilReset(now: now) else { return nil }
            return (window, seconds)
        }

        let futureCandidates = candidates.filter { $0.seconds > 0 }
        if let next = futureCandidates.min(by: { $0.seconds < $1.seconds }) {
            return next.window
        }

        return candidates.max(by: { $0.seconds < $1.seconds })?.window
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
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.22))
                    .frame(height: 7)
                    .offset(y: 4)

                if isExhausted {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.red.opacity(0.26))
                        .frame(width: proxy.size.width, height: 7)
                        .offset(y: 4)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.red.opacity(0.82))
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
                                .fill(Color.red.opacity(0.82))
                                .frame(width: max(0, expectedX - actualX), height: 7)
                                .offset(x: actualX)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
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
            return .green
        case .deficit:
            return .red
        }
    }
}

private extension View {
    func popoverGlassCard() -> some View {
        self
            .background(.thinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

}

private struct MenuContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
