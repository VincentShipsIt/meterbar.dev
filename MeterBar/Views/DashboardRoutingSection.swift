import MeterBarShared
import SwiftUI

// Routing page: where each kind of work would go right now. It asks the same
// pure router as `meterbar route`, over the same cached snapshots, so the page
// and the CLI cannot disagree. It recommends and never switches an account or
// launches anything. Edit Policies changes how the router ranks; nothing is
// saved until Save.

struct DashboardRoutingSection: View {
    @State private var preview: RoutingPreview?
    @State private var editor: RoutingPolicyEditor?
    @State private var accountOptions: [RoutingPolicyEditor.AccountOption] = []
    @State private var saveError: String?

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

            if let editing = Binding($editor) {
                RoutingPolicyEditorBar(
                    editor: editing.wrappedValue,
                    saveError: saveError,
                    onSave: save,
                    onCancel: cancelEditing,
                    onResetAll: { editor?.resetAll() }
                )
                ForEach(RoutingTaskID.builtIn, id: \.self) { task in
                    RoutingPolicyEditorCard(task: task, editor: editing, accounts: accountOptions)
                }
            } else if let preview {
                HStack {
                    Spacer()
                    Button("Edit Policies", action: startEditing)
                }
                ForEach(preview.rows) { row in
                    DashboardCard(title: row.taskName, trailing: row.isCustomized ? "Customized" : nil) {
                        RoutingRowView(row: row)
                    }
                }
            }

            DashboardCardCaption(text: Self.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: reload)
    }

    private func reload() {
        let policies = RoutingPolicyStore.load()
        let candidates = WorkloadRouteCLI.loadCandidates()
        accountOptions = RoutingPolicyEditor.accountOptions(from: candidates)
        preview = RoutingPreview.make(
            catalog: policies.catalog,
            notice: policies.notice,
            candidates: candidates,
            now: Date()
        )
    }

    private func startEditing() {
        saveError = nil
        editor = RoutingPolicyEditor(catalog: RoutingPolicyStore.load().catalog)
    }

    private func cancelEditing() {
        saveError = nil
        editor = nil
    }

    private func save() {
        guard var draft = editor else { return }
        do {
            try draft.save()
            saveError = nil
            editor = nil
            reload()
        } catch RoutingPolicyEditor.SaveError.blocked(let reason) {
            saveError = reason
        } catch RoutingPolicyEditor.SaveError.storage(let reason) {
            saveError = reason
        } catch {
            saveError = error.localizedDescription
        }
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
