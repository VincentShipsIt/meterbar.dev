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
        SettingsRowView(title: "Total cost") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(summary.formattedTotalCost)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                convertedCaption(summary.totalCostUSD)
            }
        }

        SettingsRowView(title: "Daily average") {
            Text(summary.formattedDailyCost)
                .foregroundColor(.secondary)
        }

        ForEach(summary.costs) { cost in
            SettingsRowView(title: cost.provider.displayName) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(cost.formattedCost)
                        .font(.caption)
                        .fontWeight(.semibold)
                    convertedCaption(cost.estimatedCostUSD)
                    Text("\(cost.formattedTokens) tokens")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Per-project/worktree rollup (issue #270): every scanned session
            // attributes to exactly one row here, including the explicit
            // "unknown" bucket for anything unattributable — never dropped,
            // never guessed.
            if !cost.projectBreakdowns.isEmpty {
                projectBreakdownRows(cost.projectBreakdowns)
            }
        }
    }

    /// Driven by a `TimelineView` tick rather than plain re-render, because
    /// SwiftUI only recomputes a view when its inputs change: a settings
    /// window left open across midnight on the 1st would otherwise keep
    /// showing last month's window until unrelated state moved. Same
    /// one-minute schedule the other time-driven settings rows already use.
    @ViewBuilder private var monthToDateContent: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 10) {
                monthToDateRows(now: context.date)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func monthToDateRows(now: Date) -> some View {
        let window = summary.monthToDateCostWindow(now: now)

        SettingsRowView(title: "Total cost") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(window.formattedTotalCost)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                convertedCaption(window.totalCostUSD)
            }
        }

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
            ForEach(window.providers) { provider in
                SettingsRowView(title: provider.provider.displayName) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(provider.formattedCost)
                            .font(.caption)
                            .fontWeight(.semibold)
                        convertedCaption(provider.estimatedCostUSD)
                        // Daily rows carry no cache-creation tokens or session
                        // counts, so this reports input+output+cache-read only —
                        // matching `ProviderDailyTotal.totalTokens` exactly.
                        Text("\(UsageFormat.groupedTokens(provider.totalTokens)) tokens")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    /// Rollup view plus drill-down to model breakdown (issue #270): each
    /// project/worktree row expands to the models used within it, without
    /// duplicating the rollup row's own layout.
    @ViewBuilder
    private func projectBreakdownRows(_ projects: [TokenUsageBreakdown]) -> some View {
        ForEach(projects.sorted(by: { $0.estimatedCostUSD > $1.estimatedCostUSD })) { project in
            DisclosureGroup {
                ForEach(project.modelBreakdowns) { model in
                    HStack {
                        Text(model.name)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(model.formattedCost)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.leading, 20)
                }
            } label: {
                HStack(alignment: .top) {
                    Text(project.name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(project.formattedCost)
                            .font(.caption)
                            .fontWeight(.semibold)
                        convertedCaption(project.estimatedCostUSD)
                        Text("\(project.sessionCount) session\(project.sessionCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.leading, 8)
            .accessibilityIdentifier("project-breakdown-\(project.name)")
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

/// The "Cost" settings tab: local session cost scan results, the 30-day scan
/// control, and (issue #270) the month-to-date period switch and the display
/// currency preference. Extracted from the SettingsView monolith.
struct CostSettingsView: View {
    // MARK: Internal

    var body: some View {
        costTrackingSection
        displayCurrencySection
    }

    // MARK: Private

    @StateObject private var costTracker = CostTracker.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var displayCurrencyStore = DisplayCurrencyStore.shared

    @State private var periodMode: CostPeriodMode = .last30Days
    @State private var currencyCodeInput: String = ""
    @State private var currencyRateInput: String = ""

    private var visibleCostSummary: CostSummary? {
        costTracker.costSummary?.filtered(to: providerVisibility.enabledServices)
    }

    private var canScanCosts: Bool {
        providerVisibility.isEnabled(.claudeCode) || providerVisibility.isEnabled(.codexCli)
    }

    private var costTrackingSection: some View {
        SettingsPanelSection(title: "Cost Tracking", systemImage: "chart.bar.xaxis", color: MeterBarTheme.success) {
            if costTracker.isScanning {
                SettingsRowView(title: "Status") {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Scanning sessions...")
                            .foregroundColor(.secondary)
                    }
                }
            } else if let summary = visibleCostSummary, !summary.costs.isEmpty {
                periodPicker

                CostPeriodContentView(summary: summary, periodMode: periodMode, currency: displayCurrencyStore.currency)

                if let lastScan = costTracker.lastScanDate {
                    SettingsNotice(text: "Last scanned \(formatDate(lastScan)) ago.", color: .secondary)
                }
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

            SettingsRowView(title: "Local sessions") {
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
                            Text(costTracker.isRefreshingMissingDays ? "Updating..." : "Scanning...")
                        } else {
                            Image(systemName: "magnifyingglass")
                            Text("Scan 30 Days")
                        }
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(costTracker.isRefreshInProgress || !canScanCosts)
            }
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

    /// Presentation-only currency preference entry (issue #270). MeterBar
    /// never fetches a live rate — this only accepts what the user types —
    /// and the disclosure notice below always pairs the stored rate with the
    /// date it was entered so a converted figure can't read as a live quote.
    /// Shown regardless of scan state: entering a rate ahead of the first
    /// scan is harmless, since it only affects how future totals render.
    private var displayCurrencySection: some View {
        SettingsPanelSection(title: "Display Currency", systemImage: "banknote", color: MeterBarTheme.warning) {
            Text("Converts the totals above for display only. Stored and exported cost data always stays USD.")
                .font(.caption)
                .foregroundColor(.secondary)

            SettingsRowView(title: "Currency code") {
                TextField("e.g. EUR", text: $currencyCodeInput)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("display-currency-code-field")
            }

            SettingsRowView(title: "Units per 1 USD") {
                TextField("e.g. 0.92", text: $currencyRateInput)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("display-currency-rate-field")
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button("Save") {
                    guard let rate = parsedCurrencyRate else { return }
                    displayCurrencyStore.set(code: currencyCodeInput, rate: rate)
                }
                .buttonStyle(.bordered)
                .disabled(
                    currencyCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || parsedCurrencyRate == nil
                )
                .accessibilityIdentifier("display-currency-save-button")

                if displayCurrencyStore.currency != nil {
                    Button("Clear", role: .destructive) {
                        displayCurrencyStore.clear()
                        currencyCodeInput = ""
                        currencyRateInput = ""
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("display-currency-clear-button")
                }
            }

            if let currency = displayCurrencyStore.currency {
                SettingsNotice(text: currency.disclosureText, color: .secondary)
            }
        }
        .onAppear(perform: syncCurrencyInputsFromStore)
    }

    /// `Double("inf")` and `Double("nan")` both parse, so plain
    /// `Double(_:) != nil` would enable Save for a rate that can only render
    /// as "inf". The store rejects those too; this keeps the button honest.
    private var parsedCurrencyRate: Double? {
        guard let rate = Double(currencyRateInput), rate > 0, rate.isFinite else { return nil }
        return rate
    }

    private func syncCurrencyInputsFromStore() {
        guard let currency = displayCurrencyStore.currency else { return }
        currencyCodeInput = currency.code
        currencyRateInput = String(currency.unitsPerUSD)
    }

    private func formatDate(_ date: Date) -> String {
        UsageFormat.relative(date)
    }
}
