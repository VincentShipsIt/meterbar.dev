import AppKit
import MeterBarShared
import SwiftUI

extension ProviderStatusIndicator {
    var tint: Color {
        switch self {
        case .none:
            return MeterBarTheme.success
        case .minor, .maintenance:
            return MeterBarTheme.warning
        case .major, .critical:
            return MeterBarTheme.danger
        case .unknown:
            return .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .none:
            return "checkmark.circle.fill"
        case .minor:
            return "exclamationmark.triangle.fill"
        case .major, .critical:
            return "xmark.octagon.fill"
        case .maintenance:
            return "wrench.and.screwdriver.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }
}

struct ProviderStatusBadge: View {
    let indicator: ProviderStatusIndicator
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: indicator.symbolName)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.caption2)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .foregroundStyle(indicator.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(indicator.tint.opacity(0.14), in: Capsule())
        .overlay {
            Capsule().stroke(indicator.tint.opacity(0.18), lineWidth: 1)
        }
    }
}

struct ProviderStatusDashboardCard: View {
    let service: ServiceType
    let report: ProviderStatusReport?
    let error: String?
    let openStatusPage: (ServiceType) -> Void

    private var indicator: ProviderStatusIndicator {
        report?.summary.indicator ?? (error == nil ? .unknown : .critical)
    }

    private var headline: String {
        report?.summary.description ?? report?.summary.indicator.summaryLabel ?? "Loading status"
    }

    var body: some View {
        DashboardTile {
            VStack(alignment: .leading, spacing: 12) {
                header

                if let error, report == nil {
                    statusError(error)
                } else if let report {
                    if report.components.isEmpty {
                        Text("No component details published by \(report.pageName).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(report.components) { component in
                                ProviderStatusComponentRows(component: component)
                            }
                        }
                    }
                } else {
                    Text("Fetching provider status.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderLogoView(
                kind: .forService(service),
                size: 19,
                foregroundColor: MeterBarTheme.accent(for: service)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(service.statusPageDisplayName)
                    .font(.headline)
                    .fontWeight(.semibold)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            ProviderStatusBadge(indicator: indicator, label: headline)

            Button {
                openStatusPage(service)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Open \(service.statusPageDisplayName) status page")
        }
    }

    private var subtitle: String {
        if let updatedAt = report?.summary.updatedAt {
            return "Updated \(UsageFormat.relative(updatedAt))"
        }
        if let fetchedAt = report?.fetchedAt {
            return "Checked \(UsageFormat.relative(fetchedAt))"
        }
        return service.statusPageURLString
    }

    private func statusError(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ProviderStatusIndicator.critical.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MeterBarTheme.danger)
                .padding(.top, 1)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProviderStatusComponentRows: View {
    let component: ProviderStatusComponent

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ProviderStatusComponentRow(component: component)
            if component.isGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(component.children) { child in
                        ProviderStatusComponentRow(component: child, indented: true)
                    }
                }
            }
        }
    }
}

private struct ProviderStatusComponentRow: View {
    let component: ProviderStatusComponent
    var indented = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(component.indicator.tint)
                .frame(width: 8, height: 8)

            Text(component.name)
                .font(.subheadline)
                .lineLimit(1)

            Spacer(minLength: 12)

            Text(component.statusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, indented ? 18 : 0)
    }
}

struct PopoverProviderStatusSummaryCard: View {
    @StateObject private var statusMonitor = ProviderStatusMonitor.shared

    let openStatusDashboard: () -> Void

    private var reports: [ProviderStatusReport] {
        ServiceType.allCases.compactMap { statusMonitor.reports[$0] }
    }

    private var worstIndicator: ProviderStatusIndicator {
        reports
            .map(\.summary.indicator)
            .max { $0.rank < $1.rank } ?? (statusMonitor.isRefreshing ? .unknown : .none)
    }

    private var summaryText: String {
        if statusMonitor.isRefreshing, reports.isEmpty {
            return "Checking provider status"
        }

        let issueCount = reports.filter(\.hasIssue).count
        if issueCount == 0, reports.count == ServiceType.allCases.count {
            return "All provider pages operational"
        }
        if issueCount == 1 {
            return "1 provider needs attention"
        }
        if issueCount > 1 {
            return "\(issueCount) providers need attention"
        }
        return "Status pages available"
    }

    var body: some View {
        Button(action: openStatusDashboard) {
            DashboardTile(padding: 11, minHeight: 58, alignment: .center) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(worstIndicator.tint)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Provider Status")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text(summaryText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 5) {
                        ForEach(ServiceType.allCases) { service in
                            Circle()
                                .fill((statusMonitor.reports[service]?.summary.indicator ?? .unknown).tint)
                                .frame(width: 7, height: 7)
                                .help(service.statusPageDisplayName)
                        }
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .task {
            await statusMonitor.refreshAllIfNeeded()
        }
    }
}
