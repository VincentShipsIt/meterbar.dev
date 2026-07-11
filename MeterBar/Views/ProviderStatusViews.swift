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

/// Dashboard Status section: one row per provider, collapsed to a summary
/// line and expandable in place to show the component details.
struct ProviderStatusTable: View {
    let reports: [ServiceType: ProviderStatusReport]
    let errors: [ServiceType: String]
    let openStatusPage: (ServiceType) -> Void

    @State private var expandedServices: Set<ServiceType> = []

    var body: some View {
        DashboardTile(padding: 8) {
            VStack(spacing: 0) {
                ForEach(Array(ServiceType.allCases.enumerated()), id: \.element) { index, service in
                    if index > 0 {
                        Divider()
                            .padding(.horizontal, 6)
                    }

                    ProviderStatusDisclosureRow(
                        service: service,
                        report: reports[service],
                        error: errors[service],
                        isExpanded: expandedServices.contains(service),
                        toggle: { toggleExpansion(for: service) },
                        openStatusPage: { openStatusPage(service) }
                    )
                }
            }
        }
    }

    private func toggleExpansion(for service: ServiceType) {
        withAnimation(.snappy(duration: 0.18)) {
            if expandedServices.contains(service) {
                expandedServices.remove(service)
            } else {
                expandedServices.insert(service)
            }
        }
    }
}

private struct ProviderStatusDisclosureRow: View {
    let service: ServiceType
    let report: ProviderStatusReport?
    let error: String?
    let isExpanded: Bool
    let toggle: () -> Void
    let openStatusPage: () -> Void

    private var indicator: ProviderStatusIndicator {
        report?.summary.indicator ?? (error == nil ? .unknown : .critical)
    }

    private var headline: String {
        report?.summary.description ?? report?.summary.indicator.summaryLabel ?? "Loading status"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Button(action: toggle) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)
                            .frame(width: 12)

                        ProviderLogoView(
                            kind: .forService(service),
                            size: 17,
                            foregroundColor: MeterBarTheme.accent(for: service)
                        )

                        VStack(alignment: .leading, spacing: 1) {
                            Text(service.statusPageDisplayName)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 10)

                        ProviderStatusBadge(indicator: indicator, label: headline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded ? "Collapse status details" : "Show status details")

                Button(action: openStatusPage) {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Open \(service.statusPageDisplayName) status page")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)

            if isExpanded {
                expandedDetails
                    .padding(.leading, 28)
                    .padding(.trailing, 6)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder private var expandedDetails: some View {
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
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            ProviderStatusComponentRow(component: component, compact: compact)
            if component.isGroup {
                VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                    ForEach(component.children) { child in
                        ProviderStatusComponentRow(component: child, indented: true, compact: compact)
                    }
                }
            }
        }
    }
}

private struct ProviderStatusComponentRow: View {
    let component: ProviderStatusComponent
    var indented = false
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(component.indicator.tint)
                .frame(width: compact ? 6 : 8, height: compact ? 6 : 8)

            Text(component.name)
                .font(compact ? .caption : .subheadline)
                .lineLimit(1)

            Spacer(minLength: 12)

            Text(component.statusLabel)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, indented ? (compact ? 14 : 18) : 0)
    }
}

struct PopoverProviderStatusSummaryCard: View {
    @StateObject private var statusMonitor = ProviderStatusMonitor.shared

    let openStatusDetail: () -> Void

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
        Button(action: openStatusDetail) {
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

/// Secondary popover card with the per-provider status page details, presented
/// next to the popover like the provider detail card.
struct MenuBarStatusDetailContent: View {
    @StateObject private var statusMonitor = ProviderStatusMonitor.shared

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
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 10)

            Divider()

            ViewThatFits(in: .vertical) {
                detailRows

                ScrollView(showsIndicators: false) {
                    detailRows
                }
                .scrollIndicators(.hidden)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MeterBarCompanionSurface(radius: MeterBarMenuDetailPanelLayout.cornerRadius))
        .clipShape(
            RoundedRectangle(
                cornerRadius: MeterBarMenuDetailPanelLayout.cornerRadius,
                style: .continuous
            )
        )
        .task {
            await statusMonitor.refreshAllIfNeeded()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(worstIndicator.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("Provider Status")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(summaryText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ServiceType.allCases) { service in
                MenuBarStatusDetailProviderSection(
                    service: service,
                    report: statusMonitor.reports[service],
                    error: statusMonitor.errors[service]
                )
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct MenuBarStatusDetailProviderSection: View {
    let service: ServiceType
    let report: ProviderStatusReport?
    let error: String?

    private var indicator: ProviderStatusIndicator {
        report?.summary.indicator ?? (error == nil ? .unknown : .critical)
    }

    private var headline: String {
        report?.summary.description ?? report?.summary.indicator.summaryLabel ?? "Loading status"
    }

    private var subtitle: String? {
        if let updatedAt = report?.summary.updatedAt {
            return "Updated \(UsageFormat.relative(updatedAt))"
        }
        if let fetchedAt = report?.fetchedAt {
            return "Checked \(UsageFormat.relative(fetchedAt))"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                ProviderLogoView(
                    kind: .forService(service),
                    size: 15,
                    foregroundColor: MeterBarTheme.accent(for: service)
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(service.statusPageDisplayName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                ProviderStatusBadge(indicator: indicator, label: headline)

                Button {
                    if let url = service.statusPageURL {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Open \(service.statusPageDisplayName) status page")
            }

            if let error, report == nil {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let report {
                if report.components.isEmpty {
                    Text("No component details published by \(report.pageName).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(report.components) { component in
                            ProviderStatusComponentRows(component: component, compact: true)
                        }
                    }
                }
            } else {
                Text("Fetching provider status.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .meterBarCardSurface(cornerRadius: 10)
    }
}
