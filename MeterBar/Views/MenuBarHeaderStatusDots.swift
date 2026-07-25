import MeterBarShared
import SwiftUI

/// Accessibility copy for the header status pill.
///
/// Lifted out of the view so the singular/plural rule is assertable without a
/// live `ProviderStatusMonitor`. Deliberately *not* merged with
/// `MenuBarStatusDetailContent.summaryText` or `DashboardStatusSection.summary`:
/// all three read similarly but answer different questions (this one has no
/// "checking" state and no partial-sweep guard), so folding them together would
/// change behaviour rather than remove duplication.
enum ProviderStatusDotsSummary {
    static func text(issueCount: Int) -> String {
        if issueCount == 0 { return "All provider pages operational" }
        return issueCount == 1 ? "1 provider needs attention" : "\(issueCount) providers need attention"
    }
}

/// The provider-status indicator, promoted from a full popover card into the top
/// bar: just the per-provider dots in a glass pill (matching the header's other
/// glass controls). Tap — or hover — to open the status detail panel.
struct PopoverHeaderStatusDots: View {
    @StateObject private var statusMonitor = ProviderStatusMonitor.shared
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    let openDetail: () -> Void
    var hoverOpenDetail: (() -> Void)?

    private var summaryText: String {
        let issues = ServiceType.allCases
            .compactMap { statusMonitor.reports[$0] }
            .filter(\.hasIssue)
            .count
        return ProviderStatusDotsSummary.text(issueCount: issues)
    }

    var body: some View {
        Button(action: openDetail) {
            HStack(spacing: 5) {
                ForEach(ServiceType.allCases) { service in
                    let indicator = statusMonitor.reports[service]?.summary.indicator ?? .unknown
                    Circle()
                        .fill(indicator.tint)
                        .frame(width: 7, height: 7)
                        .help(service.statusPageDisplayName)
                        .animation(
                            MeterBarTheme.Motion.snappy(reduceMotion: reduceMotion),
                            value: indicator
                        )
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help("Provider status")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Provider status")
        .accessibilityValue(summaryText)
        .accessibilityHint("Show provider status details")
        .onHover { if $0 { hoverOpenDetail?() } }
        .task { await statusMonitor.refreshAllIfNeeded() }
    }
}
