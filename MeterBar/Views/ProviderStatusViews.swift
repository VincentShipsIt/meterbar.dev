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
        // Migrated to the shared `MeterBarChip` — this recipe was already the
        // closest to the standard (fill 0.14 + stroke 0.18), so only the padding
        // scale is normalized.
        MeterBarChip(label, systemImage: indicator.symbolName, tint: indicator.tint, style: .flat)
    }
}

/// Dashboard Status section: one row per provider, collapsed to a summary
/// line and expandable in place to show the component details.
struct ProviderStatusTable: View {
    let reports: [ServiceType: ProviderStatusReport]
    let errors: [ServiceType: String]
    let openStatusPage: (ServiceType) -> Void

    @State private var expandedServices: Set<ServiceType> = []
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        // One tile per provider, like the popover's status detail sections —
        // the previous single divider-separated tile read as one blurred list,
        // and its unclipped move-in transition drew the expanding content on
        // top of the row above it.
        VStack(spacing: MeterBarTheme.Spacing.sm) {
            ForEach(ServiceType.statusPageServices) { service in
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

    private func toggleExpansion(for service: ServiceType) {
        withAnimation(reduceMotion ? nil : MeterBarTheme.Motion.disclosure) {
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

    @State private var showsAllComponents = false
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    private var indicator: ProviderStatusIndicator {
        report?.summary.indicator ?? (error == nil ? .unknown : .critical)
    }

    private var headline: String {
        if let report {
            return report.headline
        }
        return error == nil ? "Loading" : "Unavailable"
    }

    var body: some View {
        DashboardTile(padding: .popover) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    Button(action: toggle) {
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.secondary)
                                .frame(width: 12)
                                .contentTransition(.symbolEffect(.replace))
                                .animation(MeterBarTheme.Motion.snappy(reduceMotion: reduceMotion), value: isExpanded)

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

                if isExpanded {
                    // Fade only: the tile's height change carries the motion.
                    // The old `.move(edge: .top)` slid the incoming rows over
                    // the header because nothing clipped them mid-flight.
                    expandedDetails
                        .padding(.top, MeterBarTheme.Spacing.md)
                        .padding(.leading, MeterBarTheme.Spacing.xxl)
                        .transition(.opacity)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: MeterBarTheme.Radius.card, style: .continuous))
    }

    @ViewBuilder private var expandedDetails: some View {
        if let error, report == nil {
            statusError(error)
        } else if let report {
            if report.components.isEmpty {
                Text(report.unreadableReason ?? "No component details published by \(report.pageName).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ProviderStatusComponentList(
                    components: report.components,
                    showsAll: $showsAllComponents
                )
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
                .padding(.top, MeterBarTheme.Spacing.xxs)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// Component rows capped at `ProviderStatusComponentPresentation.defaultLimit`
/// with a "+N more" / "Show less" toggle, shared by the dashboard table and
/// the popover status card. Issues sort first so the cap never hides them.
private struct ProviderStatusComponentList: View {
    let components: [ProviderStatusComponent]
    @Binding var showsAll: Bool
    var compact = false

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    private var presentation: ProviderStatusComponentPresentation {
        .make(components: components, expanded: showsAll)
    }

    private var canCollapse: Bool {
        components.count > ProviderStatusComponentPresentation.defaultLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            ForEach(presentation.visible) { component in
                ProviderStatusComponentRows(component: component, compact: compact)
            }

            if presentation.isTruncated || (showsAll && canCollapse) {
                Button {
                    withAnimation(reduceMotion ? nil : MeterBarTheme.Motion.disclosure) {
                        showsAll.toggle()
                    }
                } label: {
                    Label(
                        showsAll ? "Show less" : "+\(presentation.hiddenCount) more",
                        systemImage: showsAll ? "chevron.up.circle" : "ellipsis.circle"
                    )
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityHint(showsAll ? "Collapse component list" : "Show all components")
            }
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

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(component.indicator.tint)
                .frame(width: compact ? 6 : 8, height: compact ? 6 : 8)
                // Status dots are `Circle` fills, not SF Symbols, so animate the
                // tint change on refresh rather than a symbol replace.
                .animation(MeterBarTheme.Motion.snappy(reduceMotion: reduceMotion), value: component.indicator)

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

/// Secondary popover card with the per-provider status page details, presented
/// next to the popover like the provider detail card.
struct MenuBarStatusDetailContent: View {
    @StateObject private var statusMonitor = ProviderStatusMonitor.shared
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    var isPresented = true

    var body: some View {
        ViewThatFits(in: .vertical) {
            detailRows
            ScrollView { detailRows }
                .scrollIndicators(.never)
                .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task { await statusMonitor.refreshAllIfNeeded() }
    }

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: MenuBarPopoverGeometry.cardGap) {
            ForEach(ServiceType.statusPageServices) { service in
                HoverCardSurface(revealed: isPresented, reduceMotion: reduceMotion) {
                    MenuBarStatusDetailProviderSection(
                        service: service,
                        report: statusMonitor.reports[service],
                        error: statusMonitor.errors[service]
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct MenuBarStatusDetailProviderSection: View {
    let service: ServiceType
    let report: ProviderStatusReport?
    let error: String?

    @State private var showsAllComponents = false

    private var indicator: ProviderStatusIndicator {
        report?.summary.indicator ?? (error == nil ? .unknown : .critical)
    }

    private var headline: String {
        if let report {
            return report.headline
        }
        return error == nil ? "Loading" : "Unavailable"
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
            HStack(alignment: .top, spacing: ProviderCardHeader.Layout.columnSpacing) {
                ProviderLogoView(
                    kind: .forService(service),
                    size: ProviderCardHeader.Layout.logoSize,
                    foregroundColor: MeterBarTheme.accent(for: service)
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(service.statusPageDisplayName)
                        .font(.subheadline)
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
                    Text(report.unreadableReason ?? "No component details published by \(report.pageName).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProviderStatusComponentList(
                        components: report.components,
                        showsAll: $showsAllComponents,
                        compact: true
                    )
                }
            } else {
                Text("Fetching provider status.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
