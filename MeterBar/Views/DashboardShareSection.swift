import AppKit
import MeterBarShared
import SwiftUI
import UniformTypeIdentifiers

// Share page extracted from UsageDashboardView.swift (C1 split). The page takes
// the card's inputs explicitly and writes the "generated at" stamp back through
// a binding, because the toolbar's Refresh also re-stamps it. The export toast
// is a binding for a different reason: this page is a `switch` branch, so a
// page-local `@State` toast would be discarded the moment the user navigates
// away, where before the split it lived on the shell and survived. The
// enabled-source labels are lifted to a static so the card's provenance line can
// be asserted without hosting the page.

struct DashboardShareSection: View {
    private let costSummary: CostSummary?
    private let providerTitles: [String]
    private let viewportWidth: CGFloat
    private let horizontalInsets: CGFloat

    @Binding private var generatedAt: Date
    @Binding private var shareStatus: String?

    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var costTracker = CostTracker.shared

    init(
        costSummary: CostSummary?,
        providerTitles: [String],
        viewportWidth: CGFloat,
        horizontalInsets: CGFloat,
        generatedAt: Binding<Date>,
        shareStatus: Binding<String?>
    ) {
        self.costSummary = costSummary
        self.providerTitles = providerTitles
        self.viewportWidth = viewportWidth
        self.horizontalInsets = horizontalInsets
        self._generatedAt = generatedAt
        self._shareStatus = shareStatus
    }

    /// The card's provenance line. Only the three log-backed providers contribute
    /// a local source; the API-only ones have nothing on disk to cite.
    static func enabledSourceLabels(for enabledServices: Set<ServiceType>) -> [String] {
        var labels: [String] = []
        if enabledServices.contains(.codexCli) {
            labels.append("Codex logs")
        }
        if enabledServices.contains(.claudeCode) {
            labels.append("Claude JSONL")
        }
        if enabledServices.contains(.cursor) {
            labels.append("Cursor local state")
        }
        return labels
    }

    var body: some View {
        let previewSize = SocialShareCardLayout.previewSize(
            viewportWidth: viewportWidth,
            horizontalInsets: horizontalInsets
        )

        return VStack(alignment: .leading, spacing: 14) {
            SocialShareCardPreview(content: cardContent, size: previewSize)
                .accessibilityLabel("MeterBar 30-day token receipt preview")

            HStack(spacing: 10) {
                Button {
                    copyCardImage()
                } label: {
                    Label("Copy PNG", systemImage: "doc.on.doc")
                }
                .buttonStyle(.glassProminent)

                Button {
                    saveCardImage()
                } label: {
                    Label("Save PNG", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Button {
                    copyCaption()
                } label: {
                    Label("Copy Caption", systemImage: "text.quote")
                }
                .buttonStyle(.bordered)

                if costSummary?.dailyUsage.isEmpty ?? true {
                    Button {
                        Task {
                            await costTracker.scanCosts(days: 30)
                            generatedAt = Date()
                        }
                    } label: {
                        Label("Scan 30 Days", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .disabled(costTracker.isRefreshInProgress)
                }

                Spacer()

                if let shareStatus {
                    Text(shareStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .transition(.opacity)
                }
            }

            DashboardCard(title: "Share Caption") {
                Text(cardContent.shareCaption)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardContent: SocialShareCardContent {
        makeCardContent(generatedAt: generatedAt)
    }

    private func makeCardContent(generatedAt: Date) -> SocialShareCardContent {
        SocialCardRenderer.content(
            costSummary: costSummary,
            providerSnapshotTitles: providerTitles,
            enabledSourceLabels: Self.enabledSourceLabels(for: providerVisibility.enabledServices),
            generatedAt: generatedAt
        )
    }

    /// Each export re-stamps the card so the exported artwork and the on-screen
    /// preview agree on when it was generated.
    private func stampedContent() -> SocialShareCardContent {
        let now = Date()
        let content = makeCardContent(generatedAt: now)
        generatedAt = now
        return content
    }

    private func copyCardImage() {
        guard let image = SocialCardRenderer.image(for: stampedContent()) else {
            setShareStatus("PNG render failed")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects([image]) {
            setShareStatus("PNG copied")
        } else {
            setShareStatus("Copy failed")
        }
    }

    private func saveCardImage() {
        let content = stampedContent()

        guard let pngData = SocialCardRenderer.pngData(for: content) else {
            setShareStatus("PNG render failed")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = content.defaultFilename
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                // Deliberately not routed through `SecureFileWriter`: the user
                // picked this destination in order to share the card, so the
                // owner-only default the app applies to its own state would be
                // wrong here. Normal umask semantics are the correct behavior.
                try pngData.write(to: url, options: .atomic)
                setShareStatus("PNG saved")
            } catch {
                setShareStatus("Save failed")
            }
        }
    }

    private func copyCaption() {
        let content = stampedContent()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content.shareCaption, forType: .string)
        setShareStatus("Caption copied")
    }

    private func setShareStatus(_ status: String) {
        withAnimation(MeterBarTheme.Motion.standard) {
            shareStatus = status
        }
    }
}
