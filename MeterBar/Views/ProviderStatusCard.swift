import Foundation
import MeterBarShared
import SwiftUI

// Non-private so the shared card shell can be rendered in both usage states by
// `LiquidGlassP1RegressionTests`.
struct ProviderStatusCard: View {
    let snapshot: ProviderSnapshot
    var onSelect: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var limitDensity: LimitRow.Density = .compact
    var badgeStyle: ProviderStatusBadges.Style = .compact
    var tilePadding: MeterBarTheme.CardPadding = .popover

    @ObservedObject private var menuBarDisplayPreferences = MenuBarDisplayPreferencesStore.shared
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @StateObject private var codexService = CodexCliLocalService.shared
    @StateObject private var codexAccounts = CodexAccountStore.shared
    @StateObject private var grokService = GrokCLIUsageService.shared
    @StateObject private var grokAccounts = GrokAccountStore.shared
    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var failoverSettings = AccountFailoverSettingsStore.shared
    // Session-scoped rather than per-card `@State`: this card's identity is not
    // stable across dashboard re-deals, and losing the record re-offers a credit
    // that was already spent.
    @StateObject private var resetCreditConsumptions = CodexResetCreditConsumptionStore.shared
    @State private var isResetCreditAuthenticated = false
    @State private var isConsumingResetCredit = false
    @State private var showingResetCreditConfirmation = false
    @State private var resetCreditAlertTitle = ProviderCardResetCreditOutcome.failureTitle
    @State private var resetCreditAlertMessage: String?

    // `onSelect` stays last so trailing-closure call sites keep binding to it.
    init(
        snapshot: ProviderSnapshot,
        onHoverChange: ((Bool) -> Void)? = nil,
        limitDensity: LimitRow.Density = .compact,
        badgeStyle: ProviderStatusBadges.Style = .compact,
        tilePadding: MeterBarTheme.CardPadding = .popover,
        onSelect: (() -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.onHoverChange = onHoverChange
        self.limitDensity = limitDensity
        self.badgeStyle = badgeStyle
        self.tilePadding = tilePadding
        self.onSelect = onSelect
    }

    /// The identity row this card shows, exposed so the hover detail panel's
    /// header can be asserted equal to it.
    var headerContent: ProviderCardHeader.Content {
        ProviderCardHeader.Content(snapshot: snapshot)
    }

    private var isLiveAccount: Bool {
        guard snapshot.isAccountCard,
              let accountID = snapshot.accountID,
              let provider = AccountFailoverProvider(service: snapshot.service) else {
            return false
        }
        return failoverSettings.activeAccountIDs[provider] == accountID
    }

    /// Cards without usage data and exhausted cards are terminal summaries. A
    /// login/waiting card has no quota detail to reveal, while an exhausted card
    /// already shows its only actionable reset information inline.
    var allowsDetailNavigation: Bool {
        ProviderCardPresentation.allowsDetailNavigation(hasSelectionHandler: onSelect != nil, snapshot: snapshot)
    }

    var body: some View {
        selectableCard
            .providerCardContextMenu(ProviderCardCommands.standard(snapshot: snapshot))
            .task(id: snapshot.updatedAt) {
                await refreshResetCreditAuthenticationState()
            }
            .confirmationDialog(
                CodexResetCreditConfirmation.title(accountName: resetCreditAccountName),
                isPresented: $showingResetCreditConfirmation,
                titleVisibility: .visible
            ) {
                Button("Use Reset Credit") { consumeResetCredit() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    CodexResetCreditConfirmation.message(
                        accountName: resetCreditAccountName,
                        availableCredits: snapshot.resetCreditsAvailable
                    )
                )
            }
            .alert(
                resetCreditAlertTitle,
                isPresented: Binding(
                    get: { resetCreditAlertMessage != nil },
                    set: { if !$0 { resetCreditAlertMessage = nil } }
                )
            ) {
                Button("OK") { resetCreditAlertMessage = nil }
            } message: {
                Text(resetCreditAlertMessage ?? "")
            }
    }

    @ViewBuilder private var selectableCard: some View {
        if let onSelect, allowsDetailNavigation {
            Button(action: onSelect) {
                cardContent
            }
            .buttonStyle(ProviderCardButtonStyle())
            .accessibilityHint("Open \(snapshot.title) provider details")
            .onHover { onHoverChange?($0) }
        } else {
            cardContent
        }
    }

    private var cardContent: some View {
        DashboardTile(padding: tilePadding) {
            cardBody
        }
        .contentShape(RoundedRectangle(cornerRadius: MeterBarTheme.Radius.card, style: .continuous))
    }

    @ViewBuilder private var cardBody: some View {
        if !snapshot.hasMetrics {
            offlineRow
        } else if ProviderCardPresentation.collapsesToLoginRow(snapshot: snapshot) {
            staleLoginRow
        } else if snapshot.hasExhaustedWeeklyLimit {
            weeklyExhaustedRow
        } else {
            expandedCardBody
        }
    }

    /// Logged-out/no-data providers are terminal status rows. Recovery belongs in
    /// Settings; the popover only needs to say that this profile is offline.
    private var offlineRow: some View {
        HStack(spacing: 7) {
            ProviderLogoView(kind: snapshot.logoKind, size: 17, foregroundColor: snapshot.accentColor)
            Text(snapshot.title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)
            Spacer(minLength: 8)
            if isLiveAccount {
                MeterBarChip("Live", tint: snapshot.accentColor, style: .glass)
            }
            ProviderCardStatusLabel(snapshot: snapshot)
        }
    }

    /// A logged-out card whose cache has aged past the collapse threshold —
    /// see `ProviderCardPresentation.collapsesToLoginRow`. One line: the gauges
    /// below described a session that ended hours ago, so the only thing worth
    /// stating is the provider and the way back in.
    private var staleLoginRow: some View {
        HStack(spacing: 7) {
            ProviderLogoView(kind: snapshot.logoKind, size: 17, foregroundColor: snapshot.accentColor)
            Text(snapshot.title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)
            Spacer(minLength: 8)
            if isLiveAccount {
                MeterBarChip("Live", tint: snapshot.accentColor, style: .glass)
            }
            ProviderCardStatusLabel(snapshot: snapshot)
        }
        .help("\(snapshot.updatedText) — log in to resume tracking")
    }

    /// A weekly block makes every shorter/model-specific gauge non-actionable.
    /// Keep the shared card surface, but collapse its content to the provider and
    /// the one reset that can restore service.
    private var weeklyExhaustedRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            ProviderBlockedUsageSummary(
                snapshot: snapshot,
                density: .popoverCard,
                showsTitle: true,
                resetTimeFormat: menuBarDisplayPreferences.resetTimeFormat
            )

            // Blocked is exactly when a banked reset is worth spending, so the
            // collapsed row states how many are left instead of hiding the count
            // behind an icon-only button. The count stands on its own when the
            // action isn't usable — a visible control that would fail is worse.
            if let resetCount = snapshot.resetCreditsAvailable, resetCount > 0 {
                Divider()
                HStack(spacing: 7) {
                    resetCreditsCountLabel(resetCount)
                    Spacer(minLength: 8)
                    if showsResetCreditAction {
                        resetCreditButton(isCompact: true)
                    }
                }
            }
        }
    }

    private func resetCreditsCountLabel(_ resetCount: Int) -> some View {
        Label(
            ProviderStatusBadges.resetCreditsLabel(resetCount),
            systemImage: "arrow.clockwise.circle.fill"
        )
        .font(.caption2)
        .fontWeight(.semibold)
        .foregroundColor(snapshot.accentColor)
        .lineLimit(1)
    }

    private var expandedCardBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Active providers keep status beside their identity. Terminal
            // summaries (Out, Offline, login required) use the compact card
            // branches above, where centering against the whole row is useful.
            ProviderCardHeader(
                snapshot: snapshot,
                showsDisclosureChevron: allowsDetailNavigation,
                showsLiveAccount: isLiveAccount
            )

            if snapshot.hasExhaustedLimit {
                BlockingLimitResetCounter(
                    windows: snapshot.resetWindows,
                    accentColor: snapshot.accentColor,
                    format: menuBarDisplayPreferences.resetTimeFormat
                )
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(snapshot.limits) { limit in
                        LimitRow(limit: limit, accentColor: snapshot.accentColor, density: limitDensity)
                    }
                }

                // `.compact` rows never draw their own footer any more (see
                // `LimitRow.Density`), so the popover card carries one shared
                // reset line for the whole card instead of repeating a
                // title/countdown per row — what visually separates the
                // terse popover from the hover detail panel, which still
                // shows each row's own footer at `.detail`/`.regular`.
                if limitDensity == .compact {
                    NextResetCountdownLabel(
                        windows: sharedResetWindows,
                        font: .caption2,
                        foregroundColor: .secondary,
                        iconSize: 9,
                        format: menuBarDisplayPreferences.resetTimeFormat
                    )
                }
            }

            let badges = ProviderStatusBadges(snapshot: snapshot, style: badgeStyle)
            if badges.hasContent {
                badges
            }

            if showsResetCreditAction {
                Divider()
                resetCreditButton(isCompact: false)
            }
        }
    }

    /// Windows for the popover card's one shared reset line — every limit that
    /// reports a reset time, titled by its own reset cadence via
    /// `NextResetCountdownLabel.counterText` (falls back to `localizedTitle`
    /// when the limit has no `periodKind`). Limits without a reset time are
    /// left out rather than passed through with a `nil` limit, since they'd
    /// never be selected by `NextResetCountdownLabel.selectNextWindow` anyway.
    private var sharedResetWindows: [ResetCountdownWindow] {
        snapshot.limits.compactMap { limit in
            guard limit.usageLimit.resetTime != nil else { return nil }
            return ResetCountdownWindow(id: limit.id, title: limit.localizedTitle, limit: limit.usageLimit)
        }
    }

    /// `isCompact` keeps the collapsed blocked row on one line; the expanded card
    /// stretches the same control to full width. One implementation either way so
    /// the two states cannot drift in copy or behavior.
    private func resetCreditButton(isCompact: Bool) -> some View {
        Button {
            showingResetCreditConfirmation = true
        } label: {
            HStack(spacing: 6) {
                if isConsumingResetCredit {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise.circle.fill")
                }
                Text(isConsumingResetCredit ? "Using reset credit…" : "Use reset credit")
                    .lineLimit(1)
            }
            .frame(maxWidth: isCompact ? nil : .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(isConsumingResetCredit)
        .help(
            CodexResetCreditConfirmation.message(
                accountName: resetCreditAccountName,
                availableCredits: snapshot.resetCreditsAvailable
            )
        )
    }

    private var showsResetCreditAction: Bool {
        ProviderCardPresentation.showsResetCreditAction(
            snapshot: snapshot,
            hasPendingConsumption: resetCreditConsumptions.hasPendingConsumption(
                accountID: snapshot.accountID,
                snapshotUpdatedAt: snapshot.updatedAt
            ),
            isAuthenticated: isResetCreditAuthenticated,
            hasResolvedAccount: resetCreditAccountID != nil
        )
    }

    private var codexAccount: CodexAccount? {
        guard snapshot.service == .codexCli, let accountID = snapshot.accountID else { return nil }
        return codexAccounts.accounts.first { $0.id == accountID }
    }

    private var grokAccount: GrokAccount? {
        guard snapshot.service == .grok, let accountID = snapshot.accountID else { return nil }
        return grokAccounts.accounts.first { $0.id == accountID }
    }

    private var resetCreditAccountID: UUID? {
        if snapshot.service == .codexCli { return codexAccount?.id }
        if snapshot.service == .grok { return grokAccount?.id }
        return nil
    }

    /// The profile name the redemption will hit — the same label Settings shows,
    /// so a multi-account popover confirms which home directory is being spent.
    private var resetCreditAccountName: String {
        if snapshot.service == .codexCli { return codexAccount?.name ?? snapshot.title }
        if snapshot.service == .grok { return grokAccount?.name ?? snapshot.title }
        return snapshot.title
    }

    private func refreshResetCreditAuthenticationState() async {
        if let codexAccount {
            isResetCreditAuthenticated = await codexService.canAccess(account: codexAccount)
            return
        }
        if let grokAccount {
            isResetCreditAuthenticated = grokService.canAccess(account: grokAccount)
            return
        }
        isResetCreditAuthenticated = false
    }

    private func consumeResetCredit() {
        guard resetCreditAccountID != nil, !isConsumingResetCredit else { return }
        isConsumingResetCredit = true

        Task {
            do {
                if snapshot.service == .codexCli, let codexAccount {
                    try await consumeCodexResetCredit(account: codexAccount)
                } else if snapshot.service == .grok, let grokAccount {
                    try await consumeGrokResetCredit(account: grokAccount)
                }
            } catch {
                present(ProviderCardResetCreditOutcome.alert(for: error))
            }
            isConsumingResetCredit = false
        }
    }

    private func consumeCodexResetCredit(account: CodexAccount) async throws {
        let result = try await codexService.consumeResetCredit(account: account)
        if let refreshedMetrics = result.refreshedMetrics {
            resetCreditConsumptions.clear(accountID: account.id)
            dataManager.applyCodexResetCreditRefresh(refreshedMetrics, accountID: account.id)
        } else {
            resetCreditConsumptions.markConsumed(accountID: account.id)
        }
        if let alert = ProviderCardResetCreditOutcome.alert(for: result) {
            present(alert)
        }
    }

    private func consumeGrokResetCredit(account: GrokAccount) async throws {
        let result = try await grokService.consumeResetCredit(account: account)
        if let refreshedMetrics = result.refreshedMetrics {
            resetCreditConsumptions.clear(accountID: account.id)
            dataManager.applyGrokResetCreditRefresh(refreshedMetrics, accountID: account.id)
        } else {
            resetCreditConsumptions.markConsumed(accountID: account.id)
        }
        if let alert = ProviderCardResetCreditOutcome.alert(for: result) {
            present(alert)
        }
    }

    private func present(_ alert: ProviderCardResetCreditOutcome.Alert) {
        resetCreditAlertTitle = alert.title
        resetCreditAlertMessage = alert.message
    }
}
