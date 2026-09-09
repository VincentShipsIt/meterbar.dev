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
//
// The page is a gallery: every shareable card at once, packed by
// `ProviderMasonryLayout`. It used to be four stacked sections — the receipt,
// its caption, one limits card behind a provider picker, and that card's
// caption — which meant the answer to "what can I post?" was three cards deep
// in a menu, and comparing two accounts was impossible without navigating.

struct DashboardShareSection: View {
    private let costSummary: CostSummary?
    private let providerSnapshots: [ProviderSnapshot]
    private let viewportWidth: CGFloat
    private let horizontalInsets: CGFloat

    @Binding private var generatedAt: Date
    @Binding private var shareStatus: String?

    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var costTracker = CostTracker.shared

    init(
        costSummary: CostSummary?,
        providerSnapshots: [ProviderSnapshot],
        viewportWidth: CGFloat,
        horizontalInsets: CGFloat,
        generatedAt: Binding<Date>,
        shareStatus: Binding<String?>
    ) {
        self.costSummary = costSummary
        self.providerSnapshots = providerSnapshots
        self.viewportWidth = viewportWidth
        self.horizontalInsets = horizontalInsets
        self._generatedAt = generatedAt
        self._shareStatus = shareStatus
    }

    /// The card's provenance line. Only providers that write local token logs
    /// contribute a source; API-only ones have nothing on disk to cite.
    static func enabledSourceLabels(for enabledServices: Set<ServiceType>) -> [String] {
        ServiceType.allCases.compactMap { service in
            guard enabledServices.contains(service), service.hasLocalHistorySource else {
                return nil
            }
            return sourceLabel(for: service)
        }
    }

    /// Share-card wording for one local-history source. Internal so the parity
    /// suite can pin the labels without duplicating them.
    static func sourceLabel(for service: ServiceType) -> String {
        switch service {
        case .claudeCode: return "Claude JSONL"
        case .codexCli: return "Codex logs"
        case .grok: return "Grok JSONL"
        case .cursor: return "Cursor local state"
        case .openRouter: return "OpenRouter logs"
        }
    }

    /// Shared with the Costs cards so the preview and the spend cards announce
    /// the same scan state in the same words — the same two flags drive both.
    static func scanStatusText(isScanning: Bool, isRefreshingMissingDays: Bool) -> String? {
        DashboardCostsSection.refreshStatusText(
            isScanning: isScanning,
            isRefreshingMissingDays: isRefreshingMissingDays
        )
    }

    /// The budgeted scan publishes partial totals after every slice, so an export
    /// taken mid-scan bakes an undercount into the PNG and the caption. Only
    /// successful exports are qualified; a failure toast is about the export
    /// itself and the caveat would only muddy it.
    static func exportStatus(_ status: String, isRefreshInProgress: Bool) -> String {
        isRefreshInProgress ? "\(status) — totals still updating" : status
    }

    /// The machine-readable export is the same versioned document the bundled
    /// CLI prints for `meterbar cost --json` — one schema, one contract
    /// (docs/cli-json-schema.md), no dashboard-only dialect to keep in sync.
    static func costJSON(summary: CostSummary, lastScanDate: Date) -> String? {
        try? CostCLIJSONResponse(
            cache: CostSummaryCache(summary: summary, lastScanDate: lastScanDate)
        ).jsonString()
    }

    /// Same UTC stamp as the PNG card's filename, so a folder of exports sorts
    /// chronologically regardless of which button produced each file.
    static func costJSONFilename(generatedAt: Date) -> String {
        "meterbar-cost-\(SocialShareCardDateFormat.filename(generatedAt)).json"
    }

    var body: some View {
        let contentWidth = ShareGalleryLayout.contentWidth(
            viewportWidth: viewportWidth,
            horizontalInsets: horizontalInsets
        )
        let columnCount = ShareGalleryLayout.columnCount(contentWidth: contentWidth)
        let previewSize = ShareGalleryLayout.previewSize(
            contentWidth: contentWidth,
            columnCount: columnCount
        )

        return VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.md) {
            galleryHeader

            ProviderMasonryLayout(
                columnCount: columnCount,
                spacing: ShareGalleryLayout.spacing
            ) {
                ForEach(entries) { entry in
                    ShareGalleryTile(
                        entry: entry,
                        previewSize: previewSize,
                        card: card(for: entry, generatedAt: generatedAt),
                        canExportCostJSON: entry.exportsCostJSON && costSummary != nil,
                        scanAction: scanAction(for: entry),
                        copyImage: { copyImage(for: entry) },
                        saveImage: { saveImage(for: entry) },
                        copyCaption: { copyCaption(for: entry) },
                        copyJSON: copyCostJSON,
                        saveJSON: saveCostJSON
                    )
                    .id(entry.id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Gallery

    private var entries: [ShareGalleryEntry] {
        ShareGalleryEntry.entries(for: providerSnapshots)
    }

    private var galleryHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: MeterBarTheme.Spacing.sm) {
            Text("Share Gallery")
                .font(.title3)
                .bold()

            if let scanStatus = Self.scanStatusText(
                isScanning: costTracker.isScanning,
                isRefreshingMissingDays: costTracker.isRefreshingMissingDays
            ) {
                Text(scanStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let shareStatus {
                Text(shareStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .transition(.opacity)
            }
        }
    }

    /// The receipt is the only card a scan can fill in, and offering the scan on
    /// a card that already has thirty days of data is noise.
    private func scanAction(for entry: ShareGalleryEntry) -> (() -> Void)? {
        guard entry.exportsCostJSON, costSummary?.dailyUsage.isEmpty ?? true else { return nil }
        guard !costTracker.isRefreshInProgress else { return nil }
        return {
            Task {
                if await costTracker.scanCosts(days: CostWindow.scanWindowDays).isAuthoritative {
                    generatedAt = Date()
                }
            }
        }
    }

    // MARK: - Card content

    /// The two card contents behind one export path. Both render through the
    /// same `SocialCardRenderer` overloads at the same size, so the gallery's
    /// buttons do not need to know which kind of card they are pointed at.
    enum GalleryCard {
        case receipt(SocialShareCardContent)
        case limits(SocialLimitsCardContent)

        var shareCaption: String {
            switch self {
            case let .receipt(content): return content.shareCaption
            case let .limits(content): return content.shareCaption
            }
        }

        var defaultFilename: String {
            switch self {
            case let .receipt(content): return content.defaultFilename
            case let .limits(content): return content.defaultFilename
            }
        }

        @MainActor var image: NSImage? {
            switch self {
            case let .receipt(content): return SocialCardRenderer.image(for: content)
            case let .limits(content): return SocialCardRenderer.image(for: content)
            }
        }

        @MainActor var pngData: Data? {
            switch self {
            case let .receipt(content): return SocialCardRenderer.pngData(for: content)
            case let .limits(content): return SocialCardRenderer.pngData(for: content)
            }
        }
    }

    private func card(for entry: ShareGalleryEntry, generatedAt: Date) -> GalleryCard {
        switch entry {
        case .receipt:
            return .receipt(makeCardContent(generatedAt: generatedAt))
        case let .limits(snapshot):
            return .limits(
                SocialLimitsCardContent(
                    snapshot: snapshot,
                    now: generatedAt,
                    generatedAt: generatedAt
                )
            )
        case .limitsPlaceholder:
            return .limits(
                SocialLimitsCardContent(
                    providerName: SocialShareCardContent.appName,
                    updatedText: "No data",
                    headline: nil,
                    rows: [],
                    generatedAt: generatedAt
                )
            )
        }
    }

    private func makeCardContent(generatedAt: Date) -> SocialShareCardContent {
        SocialCardRenderer.content(
            costSummary: costSummary,
            providerSnapshotTitles: providerSnapshots.map(\.title),
            enabledSourceLabels: Self.enabledSourceLabels(for: providerVisibility.enabledServices),
            generatedAt: generatedAt
        )
    }

    /// Each export re-stamps the card so the exported artwork and the on-screen
    /// preview agree on when it was generated.
    private func stampedCard(for entry: ShareGalleryEntry) -> GalleryCard {
        let now = Date()
        let card = card(for: entry, generatedAt: now)
        generatedAt = now
        return card
    }

    // MARK: - Exports

    private func copyImage(for entry: ShareGalleryEntry) {
        guard let image = stampedCard(for: entry).image else {
            setShareStatus("PNG render failed")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects([image]) {
            setExportStatus("PNG copied")
        } else {
            setShareStatus("Copy failed")
        }
    }

    private func saveImage(for entry: ShareGalleryEntry) {
        // The bytes are rendered now; the save panel can sit open long enough
        // for the scan to finish. The caveat has to describe the totals baked
        // into the PNG, not whatever the tracker happens to say once the user
        // has picked a destination.
        let wasRefreshInProgress = costTracker.isRefreshInProgress
        let card = stampedCard(for: entry)

        guard let pngData = card.pngData else {
            setShareStatus("PNG render failed")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = card.defaultFilename
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                // Deliberately not routed through `SecureFileWriter`: the user
                // picked this destination in order to share the card, so the
                // owner-only default the app applies to its own state would be
                // wrong here. Normal umask semantics are the correct behavior.
                try pngData.write(to: url, options: .atomic)
                setShareStatus(
                    Self.exportStatus("PNG saved", isRefreshInProgress: wasRefreshInProgress)
                )
            } catch {
                setShareStatus("Save failed")
            }
        }
    }

    private func copyCaption(for entry: ShareGalleryEntry) {
        let card = stampedCard(for: entry)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(card.shareCaption, forType: .string)
        setExportStatus("Caption copied")
    }

    private func copyCostJSON() {
        guard let json = exportableCostJSON() else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(json, forType: .string) {
            setExportStatus("JSON copied")
        } else {
            setShareStatus("Copy failed")
        }
    }

    private func saveCostJSON() {
        // Same capture as the PNG save: the bytes are built now, so the caveat
        // must describe the totals in this document, not the tracker's state
        // once the panel closes.
        let wasRefreshInProgress = costTracker.isRefreshInProgress
        guard let json = exportableCostJSON() else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.costJSONFilename(generatedAt: Date())
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                // Deliberately not routed through `SecureFileWriter` for the
                // same reason as the PNG save: a user-picked share destination
                // wants normal umask semantics, not owner-only app state.
                try Data(json.utf8).write(to: url, options: .atomic)
                setShareStatus(
                    Self.exportStatus("JSON saved", isRefreshInProgress: wasRefreshInProgress)
                )
            } catch {
                setShareStatus("Save failed")
            }
        }
    }

    /// The buttons are disabled without a summary, so the only reachable
    /// failure here is the encoder itself.
    private func exportableCostJSON() -> String? {
        guard let costSummary,
              let json = Self.costJSON(
                  summary: costSummary,
                  lastScanDate: costTracker.lastScanDate ?? Date()
              )
        else {
            setShareStatus("JSON export failed")
            return nil
        }
        return json
    }

    private func setExportStatus(_ status: String) {
        setShareStatus(Self.exportStatus(status, isRefreshInProgress: costTracker.isRefreshInProgress))
    }

    private func setShareStatus(_ status: String) {
        withAnimation(MeterBarTheme.Motion.standard) {
            shareStatus = status
        }
    }
}

// MARK: - ShareGalleryTile

/// One gallery tile: the card, what it is, the caption that ships with it, and
/// the exports that produce it.
///
/// The caption lives in the tile rather than in a section of its own — with one
/// card on the page a separate "Share Caption" card was merely redundant; with
/// six it would be six orphaned blocks of text with nothing tying each to its
/// card.
private struct ShareGalleryTile: View {
    let entry: ShareGalleryEntry
    let previewSize: CGSize
    let card: DashboardShareSection.GalleryCard
    let canExportCostJSON: Bool
    let scanAction: (() -> Void)?
    let copyImage: () -> Void
    let saveImage: () -> Void
    let copyCaption: () -> Void
    let copyJSON: () -> Void
    let saveJSON: () -> Void

    var body: some View {
        DashboardTile {
            VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: MeterBarTheme.Spacing.sm) {
                    Text(entry.title)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer(minLength: MeterBarTheme.Spacing.xs)

                    Text(entry.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                preview
                    .accessibilityLabel("\(entry.title) share card preview")

                Text(card.shareCaption)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // A narrow column cannot hold six labelled buttons on one line.
                // Rather than pick one form for every width, degrade in the
                // order that costs the least: one labelled row, then labelled
                // rows that wrap, and only then icons with tooltips.
                ViewThatFits(in: .horizontal) {
                    actions(iconOnly: false, wrapped: false)
                    actions(iconOnly: false, wrapped: true)
                    actions(iconOnly: true, wrapped: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var preview: some View {
        switch card {
        case let .receipt(content):
            SocialShareCardPreview(content: content, size: previewSize)
        case let .limits(content):
            SocialLimitsCardPreview(content: content, size: previewSize)
        }
    }

    /// Every export this tile offers, in the order they degrade.
    private var shareActions: [ShareAction] {
        var actions: [ShareAction] = [
            ShareAction(id: "copyPNG", title: "Copy PNG", symbol: "doc.on.doc", isProminent: true, run: copyImage),
            ShareAction(id: "savePNG", title: "Save PNG", symbol: "square.and.arrow.down", run: saveImage),
            ShareAction(id: "caption", title: "Copy Caption", symbol: "text.quote", run: copyCaption),
        ]

        if entry.exportsCostJSON {
            actions.append(
                ShareAction(
                    id: "copyJSON",
                    title: "Copy JSON",
                    symbol: "curlybraces",
                    isDisabled: !canExportCostJSON,
                    run: copyJSON
                )
            )
            actions.append(
                ShareAction(
                    id: "saveJSON",
                    title: "Save JSON",
                    symbol: "arrow.down.doc",
                    isDisabled: !canExportCostJSON,
                    run: saveJSON
                )
            )
        }

        if let scanAction {
            actions.append(
                ShareAction(id: "scan", title: "Scan 30 Days", symbol: "magnifyingglass", run: scanAction)
            )
        }

        return actions
    }

    private func actions(iconOnly: Bool, wrapped: Bool) -> some View {
        let rows = wrapped ? Self.rows(of: shareActions) : [shareActions]

        return VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: MeterBarTheme.Spacing.sm) {
                    ForEach(row) { action in
                        button(action, iconOnly: iconOnly)
                    }
                }
            }
        }
    }

    /// Wraps at three, which is exactly the receipt's PNG exports on the first
    /// line and its data exports on the second.
    private static func rows(of actions: [ShareAction]) -> [[ShareAction]] {
        stride(from: 0, to: actions.count, by: 3).map { start in
            Array(actions[start..<min(start + 3, actions.count)])
        }
    }

    @ViewBuilder
    private func button(_ action: ShareAction, iconOnly: Bool) -> some View {
        let label = Label(action.title, systemImage: action.symbol)
            .labelStyle(ShareActionLabelStyle(iconOnly: iconOnly))

        if action.isProminent {
            Button(action: action.run) { label }
                .buttonStyle(.glassProminent)
                .disabled(action.isDisabled)
                .help(action.title)
        } else {
            Button(action: action.run) { label }
                .buttonStyle(.bordered)
                .disabled(action.isDisabled)
                .help(action.title)
        }
    }
}

// MARK: - ShareAction

/// One export button. Modeled rather than written out inline so the tile can
/// re-lay the same set of buttons three different ways without three copies of
/// the list drifting apart.
private struct ShareAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var isProminent = false
    var isDisabled = false
    let run: () -> Void
}

// MARK: - ShareActionLabelStyle

/// Title-and-icon or icon-only, chosen at runtime.
///
/// `ViewThatFits` needs both action rows to be the same type, and the built-in
/// styles are not — so the branch lives in a style of our own rather than in a
/// conditional around each button.
private struct ShareActionLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: MeterBarTheme.Spacing.xs) {
            configuration.icon
            if !iconOnly {
                configuration.title
            }
        }
    }
}
