import MeterBarShared
import SwiftUI

// Routing page: where each kind of work would go right now. Read-only; it asks
// the same pure router as `meterbar route`, over the same cached snapshots, so
// the page and the CLI cannot disagree. It recommends and never switches an
// account or launches anything.

struct DashboardRoutingSection: View {
    @State private var preview: RoutingPreview?

    static let caption = "Recommendations only. MeterBar never switches an account or starts a task."

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let notice = preview?.notice {
                DashboardCard(title: "Policy File") {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }

            if let preview {
                ForEach(preview.rows) { row in
                    DashboardCard(title: row.taskName, trailing: row.isCustomized ? "Customized" : nil) {
                        RoutingRowView(row: row)
                    }
                }
            }

            if let preview {
                PopoverRoutingTaskPicker(options: preview.rows.compactMap { row in
                    RoutingTaskID(token: row.taskID).map { PopoverRoutingLine.Option(id: $0, name: row.taskName) }
                })
            }

            DashboardCardCaption(text: Self.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: reload)
    }

    private func reload() {
        let policies = RoutingPolicyStore.load()
        preview = RoutingPreview.make(
            catalog: policies.catalog,
            notice: policies.notice,
            candidates: WorkloadRouteCLI.loadCandidates(),
            now: Date()
        )
    }
}

private struct RoutingRowView: View {
    let row: RoutingPreview.Row

    var body: some View {
        VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
            Label(row.headline, systemImage: row.isBlocked ? "nosign" : "arrow.triangle.branch")
                .font(.headline)
                .foregroundStyle(row.isBlocked ? Color.secondary : Color.primary)

            if row.isBlocked {
                Text(row.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach(row.reasons, id: \.self) { reason in
                Text("• \(reason)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !row.fallbacks.isEmpty {
                Text("Fallbacks: " + row.fallbacks.joined(separator: " → "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !row.skipped.isEmpty {
                DisclosureGroup("Skipped (\(row.skipped.count))") {
                    VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.xs) {
                        ForEach(row.skipped) { skipped in
                            Text("• \(skipped.message)")
                                .font(.caption)
                                .foregroundStyle(skipped.isDataProblem ? Color.orange : Color.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
