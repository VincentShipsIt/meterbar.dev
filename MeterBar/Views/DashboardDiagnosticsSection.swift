import AppKit
import MeterBarShared
import SwiftUI

// Diagnostics page extracted from UsageDashboardView.swift (C1 split).
//
// Behavior change: the shell used to kick `runDiagnostics()` from its
// `onChange(of: selectedSection)` *and* this page carried its own
// `.task(id:)`, so opening Diagnostics ran the readiness sweep twice — two
// concurrent passes of keychain / file / SQLite I/O, because the `.task` path
// bypassed the in-flight guard. The page now owns the single entry point and the
// shell no longer fires one.
//
// The sweep's results live on the shell and arrive here as bindings: this page
// is a `switch` branch, so page-local `@State` would be torn down every time the
// user navigates elsewhere and the checklist would restart empty — and redo its
// keychain / file / SQLite I/O — on every single revisit.

struct DashboardDiagnosticsSection: View {
    @Binding private var readinessReports: [ProviderReadiness]
    @Binding private var isRunningDiagnostics: Bool

    init(reports: Binding<[ProviderReadiness]>, isRunning: Binding<Bool>) {
        self._readinessReports = reports
        self._isRunningDiagnostics = isRunning
    }

    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var claudeAccountStore = ClaudeCodeAccountStore.shared
    @StateObject private var claudeCodeService = ClaudeCodeLocalService.shared
    @StateObject private var codexCliService = CodexCliLocalService.shared
    @StateObject private var codexAccountStore = CodexAccountStore.shared
    @StateObject private var cursorService = CursorLocalService.shared
    @StateObject private var openRouterService = OpenRouterService.shared
    @StateObject private var grokService = GrokCLIUsageService.shared
    @StateObject private var grokAccountStore = GrokAccountStore.shared
    @StateObject private var openRouterAccountStore = OpenRouterAccountStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // No Refresh Cadence card here: cadence is configured in Settings
            // and restating it on this page was pure duplication. The copied
            // report still includes it — it is genuinely diagnostic there.
            DashboardCard(
                title: "Provider Diagnostics",
                trailing: DiagnosticsRunner.summary(for: readinessReports)
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("These checks run locally. Every line is redacted — safe to paste into a GitHub issue.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            Task { await runDiagnostics() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(isRunningDiagnostics)
                        .help("Re-run every provider readiness check")

                        Button {
                            copyDiagnosticsToClipboard()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .disabled(readinessReports.isEmpty)
                        .help("Copy the redacted diagnostics report")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if readinessReports.isEmpty {
                DashboardCard(title: "Running checks…") {
                    Text("Gathering provider setup status.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                ReadinessChecklist(reports: readinessReports)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: diagnosticsInputKey) {
            await runDiagnostics()
        }
    }

    private var diagnosticsInputKey: DiagnosticsRunner.InputKey {
        DiagnosticsRunner.InputKey(
            providers: ServiceType.allCases.filter { providerVisibility.enabledServices.contains($0) },
            defaultClaudeAccountEnabled: claudeAccountStore.defaultAccountIsEnabled,
            enabledClaudeCustomAccountIDs: claudeAccountStore.enabledAccounts
                .filter { !$0.isDefault }
                .map(\.id),
            enabledCodexAccountIDs: codexAccountStore.enabledAccounts.map(\.id),
            enabledGrokAccountIDs: grokAccountStore.enabledAccounts.map(\.id),
            enabledOpenRouterKeyIDs: openRouterAccountStore.enabledAccounts.map(\.id)
        )
    }

    private var refreshCadenceDiagnostic: DiagnosticsRunner.RefreshCadence {
        DiagnosticsRunner.refreshCadence(
            selection: dataManager.refreshInterval,
            effectiveInterval: dataManager.scheduledRefreshInterval,
            reason: dataManager.effectiveRefreshReason
        )
    }

    /// Runs the readiness inspector off the main actor (it does keychain / file /
    /// SQLite I/O) and publishes the reports back on the main actor. The only
    /// caller that can overlap this is the Re-run button, which is disabled while
    /// `isRunningDiagnostics` is set — so no in-flight guard is needed.
    @MainActor
    private func runDiagnostics() async {
        isRunningDiagnostics = true
        defer { isRunningDiagnostics = false }

        let reports = await inspectReadiness()
        guard !Task.isCancelled else { return }
        readinessReports = reports
    }

    private func inspectReadiness() async -> [ProviderReadiness] {
        let enabledProviders = providerVisibility.enabledServices
        let errors = DiagnosticsRunner.refreshErrors(
            claudeDefaultAccountEnabled: claudeAccountStore.defaultAccountIsEnabled,
            claudeError: claudeCodeService.lastError,
            codexError: codexCliService.firstError(for: codexAccountStore.enabledAccounts),
            cursorError: cursorService.lastError,
            openRouterError: openRouterService.lastError,
            grokError: grokService.firstError(for: grokAccountStore.enabledAccounts)
        )
        let accountErrors = DiagnosticsRunner.accountRefreshErrors(
            claudeAccountErrors: Dictionary(
                uniqueKeysWithValues: claudeAccountStore.enabledAccounts.compactMap { account in
                    claudeCodeService.accountErrors[account.id].map { (account.id, $0) }
                }
            ),
            codexAccountErrors: Dictionary(
                uniqueKeysWithValues: codexAccountStore.enabledAccounts.compactMap { account in
                    codexCliService.accountErrors[account.id].map { (account.id, $0) }
                }
            ),
            grokAccountErrors: Dictionary(
                uniqueKeysWithValues: grokAccountStore.enabledAccounts.compactMap { account in
                    grokService.accountErrors[account.id].map { (account.id, $0) }
                }
            ),
            openRouterKeyErrors: Dictionary(
                uniqueKeysWithValues: openRouterAccountStore.enabledAccounts.compactMap { account in
                    openRouterService.accountLastErrors[account.id].map { (account.id, $0) }
                }
            )
        )
        let defaultClaudeAccountEnabled = claudeAccountStore.defaultAccountIsEnabled
        let enabledClaudeAccounts = claudeAccountStore.enabledAccounts
        let claudeMetricsByID = Dictionary(
            uniqueKeysWithValues: enabledClaudeAccounts.compactMap { account in
                dataManager.claudeCodeAccountMetrics[account.id].map { (account.id, $0) }
            }
        )
        return await DiagnosticsRunner.inspect(
            enabledProviders: enabledProviders,
            refreshErrors: errors,
            accountRefreshErrors: accountErrors,
            claudeAccounts: claudeAccountStore.accounts,
            claudeAccountMetrics: claudeMetricsByID,
            claudeDefaultAccountEnabled: defaultClaudeAccountEnabled,
            claudeEnabledAccountMetrics: Array(claudeMetricsByID.values),
            codexAccounts: codexAccountStore.accounts,
            grokAccounts: grokAccountStore.accounts,
            openRouterAccounts: openRouterAccountStore.accounts
        )
    }

    private func copyDiagnosticsToClipboard() {
        let text = DiagnosticsRunner.reportText(
            for: readinessReports,
            refreshCadence: refreshCadenceDiagnostic
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
