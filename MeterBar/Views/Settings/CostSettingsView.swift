import MeterBarShared
import SwiftUI

/// Which calendar window the cost summary section displays (issue #270).
/// Presentation-only state — both windows read the same cached scan, no
/// rescan, so switching modes never triggers new I/O.
enum CostPeriodMode: String, CaseIterable, Identifiable {
    case last30Days
    case monthToDate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .last30Days: "Last 30 Days"
        case .monthToDate: "Month to Date"
        }
    }
}

/// Human-readable project identity for the settings drill-down. Scanner IDs
/// stay stable and lossless in the cache; this projection strips storage
/// scaffolding such as `www/` and `.claude/worktrees/...` from the UI.
nonisolated struct CostProjectPresentation: Equatable {
    let title: String
    let detail: String?

    init(identifier: String) {
        let components = identifier
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard identifier != CostProjectAttribution.unknownProjectID, !components.isEmpty else {
            title = "Unknown project"
            detail = "No working directory recorded"
            return
        }

        if let worktreesIndex = components.firstIndex(of: "worktrees") {
            let markerIndex = max(0, worktreesIndex - 1)
            let base = Array(components[..<markerIndex]).last ?? components.first ?? "Worktree"
            var branch = Array(components.dropFirst(worktreesIndex + 1))
            if let last = branch.last, Self.looksLikeWorktreeID(last) {
                branch.removeLast()
            }
            title = base
            detail = branch.isEmpty ? "Worktree" : "Worktree · \(branch.joined(separator: "/"))"
            return
        }

        title = components.last ?? identifier
        let parent = components.dropLast().filter { $0 != "www" }
        detail = parent.isEmpty ? nil : parent.suffix(2).joined(separator: "/")
    }

    /// Width and a digit, not the character class alone.
    ///
    /// The IDs this drops are the fixed 6-character lowercase-hex suffix a
    /// worktree tool appends; anything of another length is a name someone
    /// chose. `deadbeef` and `cafe123` are hex too, and a branch losing its
    /// last segment is worse than an ID surviving on screen — which is also
    /// why the all-letter hex words (`decade`, `facade`, `accede`) are spared
    /// at the cost of the 1-in-360 real IDs that draw no digit.
    private static func looksLikeWorktreeID(_ value: String) -> Bool {
        guard value.count == generatedWorktreeIDLength, value.contains(where: \.isNumber) else { return false }
        return value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static let generatedWorktreeIDLength = 6
}

/// Human-readable session identity for Costs UI. Scanner IDs stay lossless in
/// the cache and JSON; this projection shortens a UUID-like stem for display.
nonisolated struct CostSessionPresentation: Equatable {
    let title: String
    let detail: String?

    init(identifier: String, projectIdentifier: String? = nil) {
        let compact = identifier.replacingOccurrences(of: "-", with: "")
        let short = compact.count > 8 ? String(compact.prefix(8)) : identifier
        title = identifier == CostSessionAttribution.unknownSessionID
            ? "Unknown session"
            : "Session \(short)"
        if let projectIdentifier, projectIdentifier != CostProjectAttribution.unknownProjectID {
            detail = CostProjectPresentation(identifier: projectIdentifier).title
        } else {
            detail = nil
        }
    }
}

/// Renders one cost-summary period — the rolling 30-day window or the
/// calendar month-to-date window — plus its per-provider project/worktree
/// rollup and, when set, a converted-currency caption (issue #270). A pure
/// function of its inputs with no singleton access, so it can be exercised
/// directly in tests with a synthetic `CostSummary`, independent of
/// `CostTracker.shared`'s live scan state (mirrors how `SettingsPanelSection`
/// and `EmptyStateCard` are already tested standalone).
struct CostPeriodContentView: View {
    let summary: CostSummary
    let periodMode: CostPeriodMode
    let currency: DisplayCurrency?
    /// Stable clock injection for presentation tests. Production leaves this
    /// nil and keeps the minute-based TimelineView rollover behavior.
    var monthToDateNow: Date?

    init(
        summary: CostSummary,
        periodMode: CostPeriodMode,
        currency: DisplayCurrency?,
        monthToDateNow: Date? = nil
    ) {
        self.summary = summary
        self.periodMode = periodMode
        self.currency = currency
        self.monthToDateNow = monthToDateNow
    }

    var body: some View {
        switch periodMode {
        case .last30Days:
            last30DaysContent
        case .monthToDate:
            monthToDateContent
        }
    }

    // MARK: Private

    @ViewBuilder private var last30DaysContent: some View {
        summaryHero(
            totalCost: summary.formattedTotalCost,
            totalCostUSD: summary.totalCostUSD,
            dailyAverage: summary.formattedDailyCost,
            totalTokens: summary.totalTokens,
            providerCount: summary.costs.count
        )

        Divider()

        VStack(alignment: .leading, spacing: 10) {
            Text("Providers")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ForEach(summary.costs) { cost in
                CostProviderBreakdownGroup(
                    provider: cost.provider,
                    formattedCost: cost.formattedCost,
                    estimatedCostUSD: cost.estimatedCostUSD,
                    formattedTokens: "\(cost.formattedTokens) tokens",
                    projects: cost.projectBreakdowns,
                    currency: currency
                )
            }
        }
    }

    /// Driven by a `TimelineView` tick rather than plain re-render, because
    /// SwiftUI only recomputes a view when its inputs change: a settings
    /// window left open across midnight on the 1st would otherwise keep
    /// showing last month's window until unrelated state moved. Same
    /// one-minute schedule the other time-driven settings rows already use.
    @ViewBuilder private var monthToDateContent: some View {
        if let monthToDateNow {
            VStack(alignment: .leading, spacing: 10) {
                monthToDateRows(now: monthToDateNow)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    monthToDateRows(now: context.date)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func monthToDateRows(now: Date) -> some View {
        let window = summary.monthToDateCostWindow(now: now)

        summaryHero(
            totalCost: window.formattedTotalCost,
            totalCostUSD: window.totalCostUSD,
            dailyAverage: UsageFormat.cost(window.totalCostUSD / Double(max(1, window.coveredDays))),
            totalTokens: window.totalTokens,
            providerCount: window.providers.count
        )

        if window.isTruncated {
            SettingsNotice(
                text: "Cache covers \(window.coveredDays) of \(window.requestedDays) day(s) so far this month.",
                color: .secondary
            )
        }

        if window.providers.isEmpty {
            EmptyStateCard(
                systemImage: "calendar",
                title: "No data yet",
                message: "No cached daily usage recorded so far this month."
            )
        } else {
            Divider()

            Text("Providers")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ForEach(window.providers) { provider in
                CostProviderBreakdownGroup(
                    provider: provider.provider,
                    formattedCost: provider.formattedCost,
                    estimatedCostUSD: provider.estimatedCostUSD,
                    formattedTokens: "\(UsageFormat.groupedTokens(provider.totalTokens)) tokens",
                    projects: provider.projectBreakdowns ?? [],
                    currency: currency
                )
            }
        }
    }

    @ViewBuilder
    private func summaryHero(
        totalCost: String,
        totalCostUSD: Double,
        dailyAverage: String,
        totalTokens: Int,
        providerCount: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Estimated spend")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(totalCost)
                        .font(.title)
                        .fontWeight(.bold)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 16)
                convertedCaption(totalCostUSD)
            }

            HStack(spacing: MeterBarTheme.Spacing.lg) {
                CostSettingsMetric(title: "Daily average", value: dailyAverage)
                CostSettingsMetric(title: "Tokens", value: UsageFormat.tokens(totalTokens))
                CostSettingsMetric(title: "Providers", value: "\(providerCount)")
            }
        }
    }

    /// Converted-currency caption shown under a USD figure, only when the
    /// user has entered a rate. Uses `DisplayCurrency`'s shared formatter so
    /// this never drifts from the CLI's own text output.
    @ViewBuilder
    private func convertedCaption(_ usd: Double) -> some View {
        if let currency {
            Text("\u{2248} \(currency.formattedConverted(usd: usd))")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

private struct CostSettingsMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct CostProviderBreakdownGroup: View {
    let provider: ServiceType
    let formattedCost: String
    let estimatedCostUSD: Double
    let formattedTokens: String
    let projects: [TokenUsageBreakdown]
    let currency: DisplayCurrency?

    var body: some View {
        if projects.isEmpty {
            providerLabel
        } else {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(projects.sorted(by: { $0.estimatedCostUSD > $1.estimatedCostUSD })) { project in
                        CostProjectBreakdownRow(project: project, currency: currency)
                    }
                }
                .padding(.top, MeterBarTheme.Spacing.sm)
                .padding(.leading, MeterBarTheme.Spacing.xxl)
            } label: {
                providerLabel
            }
            .accessibilityIdentifier("cost-provider-\(provider.rawValue)")
        }
    }

    private var providerLabel: some View {
        HStack(spacing: 10) {
            ProviderLogoView(
                kind: .forService(provider),
                size: 18,
                foregroundColor: MeterBarTheme.accent(for: provider)
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(formattedTokens)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedCost)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                if let currency {
                    Text("≈ \(currency.formattedConverted(usd: estimatedCostUSD))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CostProjectBreakdownRow: View {
    let project: TokenUsageBreakdown
    let currency: DisplayCurrency?

    private var presentation: CostProjectPresentation {
        CostProjectPresentation(identifier: project.name)
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(project.modelBreakdowns) { model in
                    HStack {
                        Text(model.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(model.formattedCost)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, MeterBarTheme.Spacing.lg)
                }
                ForEach(project.sessionBreakdowns) { session in
                    CostSessionBreakdownRow(session: session, currency: currency)
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if let detail = presentation.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(project.formattedCost)
                        .font(.caption.monospacedDigit())
                        .fontWeight(.semibold)
                    if let currency {
                        Text("≈ \(currency.formattedConverted(usd: project.estimatedCostUSD))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(project.sessionCount) usage events")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("project-breakdown-\(project.name)")
    }
}

private struct CostSessionBreakdownRow: View {
    let session: TokenUsageBreakdown
    let currency: DisplayCurrency?

    private var presentation: CostSessionPresentation {
        CostSessionPresentation(identifier: session.name)
    }

    var body: some View {
        DisclosureGroup {
            ForEach(session.modelBreakdowns) { model in
                HStack {
                    Text(model.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(model.formattedCost)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, MeterBarTheme.Spacing.lg)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "text.alignleft")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if let detail = presentation.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(session.formattedCost)
                        .font(.caption.monospacedDigit())
                        .fontWeight(.semibold)
                    if let currency {
                        Text("≈ \(currency.formattedConverted(usd: session.estimatedCostUSD))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityIdentifier("session-breakdown-\(session.name)")
    }
}

/// The "Cost" settings tab: local session cost scan results, the 30-day scan
/// control, and (issue #270) the month-to-date period switch and the display
/// currency preference. Extracted from the SettingsView monolith.
struct CostSettingsView: View {
    // MARK: Internal

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            costTrackingSection
            displayCurrencySection
        }
    }

    // MARK: Private

    @StateObject private var costTracker = CostTracker.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var displayCurrencyStore = DisplayCurrencyStore.shared

    @State private var periodMode: CostPeriodMode = .last30Days

    private var visibleCostSummary: CostSummary? {
        costTracker.costSummary?.filtered(to: providerVisibility.enabledServices)
    }

    private var canScanCosts: Bool {
        providerVisibility.isEnabled(.claudeCode) || providerVisibility.isEnabled(.codexCli)
    }

    private var costTrackingSection: some View {
        SettingsPanelSection(title: "Local Cost", systemImage: "dollarsign.circle", color: MeterBarTheme.success) {
            costToolbar

            if let summary = visibleCostSummary, !summary.costs.isEmpty {
                Divider()

                CostPeriodContentView(summary: summary, periodMode: periodMode, currency: displayCurrencyStore.currency)

                if let lastScan = costTracker.lastScanDate {
                    SettingsNotice(text: "Last scanned \(formatDate(lastScan)) ago.", color: .secondary)
                }
            } else if costTracker.isRefreshInProgress {
                EmptyStateCard(
                    systemImage: "magnifyingglass",
                    title: "Building local cost history",
                    message: "Recent usage appears first while older local sessions finish in the background."
                )
            } else if costTracker.costSummary != nil {
                // Scanned, but nothing landed for the providers that are enabled.
                EmptyStateCard(
                    systemImage: "tray",
                    title: "No cost data",
                    message: "Enabled providers logged no local tokens in the last 30 days."
                )
            } else {
                // Never scanned this session — the button below kicks off the first scan.
                EmptyStateCard(
                    systemImage: "magnifyingglass",
                    title: "No scan yet",
                    message: "Scan 30 days to estimate local token cost."
                )
            }

            if !canScanCosts {
                EmptyStateCard(
                    systemImage: "exclamationmark.triangle.fill",
                    title: "Nothing to scan",
                    message: "Enable Claude Code or OpenAI Codex to scan local token logs.",
                    tone: .warning
                )
            }
        }
    }

    private var costToolbar: some View {
        HStack(spacing: 12) {
            periodPicker
                .frame(width: 250)

            Spacer(minLength: 12)

            Button {
                Task {
                    await costTracker.scanCosts(days: 30)
                }
            } label: {
                HStack(spacing: 7) {
                    if costTracker.isRefreshInProgress {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.75)
                        Text(costTracker.isRefreshingMissingDays ? "Updating" : "Scanning")
                    } else {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(costTracker.isRefreshInProgress || !canScanCosts)
            .accessibilityIdentifier("cost-refresh-button")
        }
    }

    /// Switches between the rolling 30-day view and the calendar
    /// month-to-date window (issue #270). Segmented to match the window
    /// pickers already used elsewhere in Settings (e.g. `ApiUsageCard`).
    private var periodPicker: some View {
        Picker("Period", selection: $periodMode) {
            ForEach(CostPeriodMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("cost-period-picker")
    }

    /// Presentation-only currency preference. USD is the default; EUR uses
    /// the ECB's daily reference feed. Stored/exported data stays USD.
    private var displayCurrencySection: some View {
        SettingsPanelSection(title: "Display Currency", systemImage: "banknote", color: MeterBarTheme.warning) {
            Text("Converts totals for display only. Stored and exported cost data always stays USD.")
                .font(.caption)
                .foregroundColor(.secondary)

            SettingsRowView(title: "Currency") {
                Picker("Display currency", selection: displayCurrencyBinding) {
                    ForEach(DisplayCurrencySelection.allCases) { selection in
                        Text(selection.title).tag(selection)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("display-currency-picker")
            }

            if displayCurrencyStore.selection == .eur {
                Text("EUR totals use the ECB reference rate, refreshed daily. The last successful rate works offline.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                SettingsRowView(title: "EUR rate") {
                    HStack(spacing: 10) {
                        if displayCurrencyStore.isRefreshingAutomaticRate {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button("Refresh Now") {
                            refreshAutomaticCurrency(force: true)
                        }
                        .buttonStyle(.bordered)
                        .disabled(displayCurrencyStore.isRefreshingAutomaticRate)
                        .accessibilityIdentifier("display-currency-refresh-button")
                    }
                }

                if let error = displayCurrencyStore.automaticRateError {
                    SettingsNotice(text: error, color: MeterBarTheme.warning)
                }
            }

            if let currency = displayCurrencyStore.currency {
                SettingsNotice(text: currency.disclosureText, color: .secondary)
            }
        }
        .onAppear {
            refreshAutomaticCurrency()
        }
    }

    private var displayCurrencyBinding: Binding<DisplayCurrencySelection> {
        Binding(
            get: { displayCurrencyStore.selection },
            set: { selection in
                displayCurrencyStore.setSelection(selection)
                if selection == .eur {
                    refreshAutomaticCurrency(force: true)
                }
            }
        )
    }

    private func refreshAutomaticCurrency(force: Bool = false) {
        Task {
            await displayCurrencyStore.refreshAutomaticCurrency(force: force)
        }
    }

    private func formatDate(_ date: Date) -> String {
        UsageFormat.relative(date)
    }
}
