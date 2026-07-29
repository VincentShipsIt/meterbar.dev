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
    @StateObject private var cursorService = CursorLocalService.shared
    @StateObject private var openRouterService = OpenRouterService.shared
    @StateObject private var grokService = GrokCLIUsageService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardCard(
                title: "Refresh Cadence",
                trailing: refreshCadenceDiagnostic.effectiveInterval
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Selected: \(refreshCadenceDiagnostic.selection)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(refreshCadenceDiagnostic.reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if dataManager.refreshInterval == .adaptive {
                        Text("Adaptive range: 1–30 minutes. Activity signals stay in memory and are never sent.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

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
                            Label("Re-run checks", systemImage: "arrow.clockwise")
                        }
                        .disabled(isRunningDiagnostics)

                        Button {
                            copyDiagnosticsToClipboard()
                        } label: {
                            Label("Copy report", systemImage: "doc.on.doc")
                        }
                        .disabled(readinessReports.isEmpty)
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
                .map(\.id)
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
            codexError: codexCliService.lastError,
            cursorError: cursorService.lastError,
            openRouterError: openRouterService.lastError,
            grokError: grokService.lastError
        )
        let defaultClaudeAccountEnabled = claudeAccountStore.defaultAccountIsEnabled
        let enabledClaudeAccounts = claudeAccountStore.enabledAccounts
        let claudeMetrics = enabledClaudeAccounts.compactMap {
            dataManager.claudeCodeAccountMetrics[$0.id]
        }
        return await DiagnosticsRunner.inspect(
            enabledProviders: enabledProviders,
            refreshErrors: errors,
            claudeDefaultAccountEnabled: defaultClaudeAccountEnabled,
            claudeEnabledAccountMetrics: claudeMetrics
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
