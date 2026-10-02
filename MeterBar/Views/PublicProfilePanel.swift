import AppKit
import SwiftUI

/// The opt-in for the anonymous public profile (#594), at the top of the Share
/// page: a toggle, the link once it is on, and the sharing actions.
///
/// Everything here reads `PublicProfileStore`, and nothing is sent until the
/// toggle is on.
struct PublicProfilePanel: View {
    @StateObject private var store: PublicProfileStore
    @State private var showsPreview = false
    @State private var confirmsReset = false
    @State private var confirmsAbandonReset = false
    @State private var copied = false

    init(store: PublicProfileStore = .shared) {
        _store = StateObject(wrappedValue: store)
    }

    var body: some View {
        DashboardTile {
            VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PublicProfilePresentation.title)
                            .font(.headline)
                        Text(PublicProfilePresentation.summary(isEnabled: store.isEnabled))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("Publish profile", isOn: enabledBinding)
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("publicProfile.toggle")
                }

                if let status = PublicProfilePresentation.statusText(
                    status: store.status,
                    lastPublishedAt: store.lastPublishedAt,
                    pendingDeletions: store.pendingDeletions.count
                ) {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(isError ? Color.red : Color.secondary)
                }

                if let url = store.profileURL {
                    linkRow(url)
                    Text(PublicProfilePresentation.publishedSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(PublicProfilePresentation.neverPublished)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DisclosureGroup("See exactly what is published", isExpanded: $showsPreview) {
                        if showsPreview {
                            ScrollView {
                                Text(PublicProfileSource.currentDocument().jsonString)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 180)
                        }
                    }
                    .font(.caption)
                }

                if store.canAbandonPendingReset {
                    Button("Create replacement link…") { confirmsAbandonReset = true }
                        .disabled(!store.canPublish)
                        .accessibilityIdentifier("publicProfile.recoverReset")
                }
            }
        }
        .confirmationDialog(
            PublicProfilePresentation.resetConfirmation,
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button("Reset link", role: .destructive) {
                Task { await store.reset(document: PublicProfileSource.currentDocument()) }
            }
        }
        .confirmationDialog(
            PublicProfilePresentation.abandonResetConfirmation,
            isPresented: $confirmsAbandonReset,
            titleVisibility: .visible
        ) {
            Button("Create replacement link", role: .destructive) {
                Task { await store.abandonPendingReset(document: PublicProfileSource.currentDocument()) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(PublicProfilePresentation.abandonResetWarning)
        }
    }

    private var isError: Bool {
        if case .error = store.status { return true }
        return false
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.isEnabled },
            set: { newValue in
                Task {
                    await store.setEnabled(newValue, document: PublicProfileSource.currentDocument())
                }
            }
        )
    }

    private func linkRow(_ url: URL) -> some View {
        HStack(spacing: MeterBarTheme.Spacing.sm) {
            Text(url.absoluteString)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(copied ? "Copied" : "Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
            Button("Open") { NSWorkspace.shared.open(url) }
            if let shareURL = PublicProfilePresentation.xShareURL(profileURL: url) {
                Button("Post to X") { NSWorkspace.shared.open(shareURL) }
            }
            Button("Reset link…") { confirmsReset = true }
        }
        .controlSize(.small)
    }
}
