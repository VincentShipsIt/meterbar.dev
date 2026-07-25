import AppKit
import MeterBarShared
import SwiftUI

// Status page extracted from UsageDashboardView.swift (C1 split). Pure move; the
// trailing summary string is lifted to a static so its "all operational" claim
// can be asserted against a partial sweep without hosting the page.

struct DashboardStatusSection: View {
    @StateObject private var providerStatusMonitor = ProviderStatusMonitor.shared

    /// Trailing summary for the status card. "All operational" is only honest
    /// once every provider has reported, so a partial sweep stays blank.
    static func summary(isRefreshing: Bool, issueCount: Int, reportCount: Int) -> String? {
        if isRefreshing {
            return "Refreshing..."
        }
        if issueCount == 0, reportCount == ServiceType.allCases.count {
            return "All operational"
        }
        if issueCount == 1 {
            return "1 issue"
        }
        if issueCount > 1 {
            return "\(issueCount) issues"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardCard(title: "Provider Status Pages", trailing: statusPagesSummary) {
                HStack(alignment: .center, spacing: 10) {
                    Text("Live status from each provider's public status page.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        Task { await providerStatusMonitor.refreshAll() }
                    } label: {
                        Label("Refresh Status", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(providerStatusMonitor.isRefreshing)
                }
            }

            ProviderStatusTable(
                reports: providerStatusMonitor.reports,
                errors: providerStatusMonitor.errors,
                openStatusPage: openStatusPage
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            await providerStatusMonitor.refreshAllIfNeeded()
        }
    }

    private var statusPagesSummary: String? {
        Self.summary(
            isRefreshing: providerStatusMonitor.isRefreshing,
            issueCount: providerStatusMonitor.reports.values.filter(\.hasIssue).count,
            reportCount: providerStatusMonitor.reports.count
        )
    }

    private func openStatusPage(for service: ServiceType) {
        guard let url = service.statusPageURL else { return }
        NSWorkspace.shared.open(url)
    }
}
