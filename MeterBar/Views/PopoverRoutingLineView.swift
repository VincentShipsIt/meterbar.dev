import MeterBarShared
import SwiftUI

/// One line at the top of the popover: where the chosen task would go right
/// now. A recommendation only; it never switches an account. Renders nothing
/// when there is no route, so the popover never shows a guess.
struct PopoverRoutingLineView: View {
    @ObservedObject private var settings = PopoverRoutingSettingsStore.shared
    @State private var line: PopoverRoutingLine?

    private static let refreshInterval: Duration = .seconds(30)

    var body: some View {
        content
            .task(id: settings.task) {
                while !Task.isCancelled {
                    line = Self.currentLine(for: settings.task)
                    try? await Task.sleep(for: Self.refreshInterval)
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let line {
            DashboardTile(padding: .popover) {
                HStack(alignment: .center, spacing: 9) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    Text(line.text)
                        .font(.caption)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Routing recommendation")
                .accessibilityValue(line.text)
            }
            .transition(MeterBarTheme.Motion.popoverTile)
        }
    }

    private static func currentLine(for task: RoutingTaskID) -> PopoverRoutingLine? {
        PopoverRoutingLine.make(
            task: task,
            catalog: RoutingPolicyStore.load().catalog,
            candidates: WorkloadRouteCLI.loadCandidates(),
            now: Date()
        )
    }
}

/// Routing-page control for which task the popover line follows.
struct PopoverRoutingTaskPicker: View {
    let options: [PopoverRoutingLine.Option]

    @ObservedObject private var settings = PopoverRoutingSettingsStore.shared

    var body: some View {
        DashboardCard(title: "Popover Line") {
            VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
                Picker("Task", selection: Binding(get: { settings.task }, set: settings.setTask)) {
                    ForEach(options) { Text($0.name).tag($0.id) }
                }
                Text("The popover shows one line with where this task would go right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
