import Foundation
import MeterBarShared
import SwiftUI

// Non-private so the shared card shell can be rendered in both usage states by
// `LiquidGlassP1RegressionTests`.
struct ProviderStatusCard: View {
    let snapshot: ProviderSnapshot
    var onSelect: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    @ObservedObject private var menuBarDisplayPreferences = MenuBarDisplayPreferencesStore.shared
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @StateObject private var codexService = CodexCliLocalService.shared
    @StateObject private var codexAccounts = CodexAccountStore.shared
    @StateObject private var dataManager = UsageDataManager.shared
    @State private var isCodexAuthenticated = false
    @State private var isConsumingResetCredit = false
    @State private var didConsumeResetCredit = false
    @State private var showingResetCreditConfirmation = false
    @State private var resetCreditAlertTitle = ProviderCardResetCreditOutcome.failureTitle
    @State private var resetCreditAlertMessage: String?

    // `onSelect` stays last so trailing-closure call sites keep binding to it.
    init(
        snapshot: ProviderSnapshot,
        onHoverChange: ((Bool) -> Void)? = nil,
        onSelect: (() -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.onHoverChange = onHoverChange
        self.onSelect = onSelect
    }

    /// The identity row this card shows, exposed so the hover detail panel's
    /// header can be asserted equal to it.
    var headerContent: ProviderCardHeader.Content {
        ProviderCardHeader.Content(snapshot: snapshot)
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
                await refreshCodexAuthenticationState()
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
        DashboardTile(padding: .popover) {
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
            Text("Offline")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
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
            Text(ProviderAuthNotice.loginRequired.shortLabel)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(MeterBarTheme.warning)
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
            // The chevron rides along only when the card opens a detail panel,
            // so "clickable" is visible instead of relying on the
            // accessibilityHint alone.
            ProviderCardHeader(snapshot: snapshot, showsDisclosureChevron: allowsDetailNavigation)

            if snapshot.hasExhaustedLimit {
                BlockingLimitResetCounter(
                    windows: snapshot.resetWindows,
                    accentColor: snapshot.accentColor,
                    format: menuBarDisplayPreferences.resetTimeFormat
                )
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(snapshot.limits) { limit in
                        LimitRow(limit: limit, accentColor: snapshot.accentColor, density: .compact)
                    }
                }
            }

            let badges = ProviderStatusBadges(snapshot: snapshot, style: .compact)
            if badges.hasContent {
                badges
            }

            if showsResetCreditAction {
                Divider()
                resetCreditButton(isCompact: false)
            }
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
            didConsumeResetCredit: didConsumeResetCredit,
            isAuthenticated: isCodexAuthenticated,
            hasResolvedAccount: codexAccount != nil
        )
    }

    private var codexAccount: CodexAccount? {
        guard snapshot.service == .codexCli, let accountID = snapshot.accountID else { return nil }
        return codexAccounts.accounts.first { $0.id == accountID }
    }

    /// The profile name the redemption will hit — the same label Settings shows,
    /// so a multi-account popover confirms which `CODEX_HOME` is being spent.
    private var resetCreditAccountName: String {
        codexAccount?.name ?? snapshot.title
    }

    private func refreshCodexAuthenticationState() async {
        guard let codexAccount else {
            isCodexAuthenticated = false
            return
        }
        isCodexAuthenticated = await codexService.canAccess(account: codexAccount)
    }

    private func consumeResetCredit() {
        guard let codexAccount, !isConsumingResetCredit else { return }
        isConsumingResetCredit = true

        Task {
            do {
                let result = try await codexService.consumeResetCredit(account: codexAccount)
                didConsumeResetCredit = true
                if let refreshedMetrics = result.refreshedMetrics {
                    dataManager.applyCodexResetCreditRefresh(refreshedMetrics, accountID: codexAccount.id)
                }
                if let alert = ProviderCardResetCreditOutcome.alert(for: result) {
                    present(alert)
                }
            } catch {
                present(ProviderCardResetCreditOutcome.alert(for: error))
            }
            isConsumingResetCredit = false
        }
    }

    private func present(_ alert: ProviderCardResetCreditOutcome.Alert) {
        resetCreditAlertTitle = alert.title
        resetCreditAlertMessage = alert.message
    }
}
