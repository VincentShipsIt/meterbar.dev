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
                        stampedCaption: { stampedCard(for: entry).shareCaption },
                        copyCaptionText: copyCaptionText,
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

    /// Copies whatever text the caption sheet ended up holding — the card's own
    /// wording is a starting point, not a contract. The card was already
    /// stamped when the sheet was seeded, so nothing is re-stamped here.
    private func copyCaptionText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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

/// One gallery tile: the card, and — on hover — the exports that produce it.
///
/// The tile is the card. It used to be a `DashboardTile` wrapping a titled
/// header, the preview, the raw caption and a button row, which stacked a
/// second card around something that is already a card, repeated a provider
/// name and timestamp the artwork prints in its own masthead, and hung three
/// lines of monospaced caption under every tile. Six of those is a wall of text
/// nobody reads. What is left is the artwork; the controls float over it when
/// the pointer is on it, and the caption is a sheet you can edit before you
/// copy it.
private struct ShareGalleryTile: View {
    let entry: ShareGalleryEntry
    let previewSize: CGSize
    let card: DashboardShareSection.GalleryCard
    let canExportCostJSON: Bool
    let scanAction: (() -> Void)?
    let copyImage: () -> Void
    let saveImage: () -> Void
    /// Stamps the card and hands back the caption to seed the sheet with, the
    /// same way an export stamps it.
    let stampedCaption: () -> String
    let copyCaptionText: (String) -> Void
    let copyJSON: () -> Void
    let saveJSON: () -> Void

    var body: some View {
        preview
            .overlay { actionOverlay }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(entry.title) share card")
            .onHover { hovering in
                withAnimation(MeterBarTheme.Motion.standard) {
                    isShowingActions = hovering
                }
            }
            .sheet(item: $caption) { caption in
                ShareCaptionSheet(
                    title: entry.title,
                    subtitle: entry.subtitle,
                    text: caption.text,
                    onCopy: copyCaptionText
                )
            }
    }

    // MARK: Private

    /// One editable caption, kept as a value so `.sheet(item:)` can key off it.
    private struct CaptionDraft: Identifiable {
        let id = UUID()
        let text: String
    }

    @State private var isShowingActions = false
    @State private var caption: CaptionDraft?

    @ViewBuilder private var preview: some View {
        switch card {
        case let .receipt(content):
            SocialShareCardPreview(content: content, size: previewSize)
        case let .limits(content):
            SocialLimitsCardPreview(content: content, size: previewSize)
        }
    }

    /// The controls live on the artwork rather than beside it. They are dimmed
    /// rather than removed when the pointer leaves, so they stay in the
    /// accessibility tree instead of being unreachable without a mouse.
    private var actionOverlay: some View {
        ZStack {
            // The scrim mutes the artwork so the controls are the only thing
            // with contrast; without it the buttons sit in the middle of a
            // 168pt hero number and neither reads.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.72))

            // A narrow column cannot hold six labelled buttons on one line.
            // Rather than pick one form for every width, degrade in the order
            // that costs the least: one labelled row, then labelled rows that
            // wrap, and only then icons with tooltips.
            ViewThatFits(in: .horizontal) {
                actions(iconOnly: false, wrapped: false)
                actions(iconOnly: false, wrapped: true)
                actions(iconOnly: true, wrapped: false)
            }
            .padding(MeterBarTheme.Spacing.md)
            // A floating toolbar over content is chrome, which is the one thing
            // `Surface.chrome` is for — see `MeterBarTheme.Surface`.
            .background { MeterBarTheme.Surface.chrome(radius: MeterBarTheme.Radius.card) }
            .padding(MeterBarTheme.Spacing.md)
        }
        .opacity(isShowingActions ? 1 : 0)
    }

    /// Every export this tile offers, in the order they degrade.
    private var shareActions: [ShareAction] {
        var actions: [ShareAction] = [
            ShareAction(id: "copyPNG", title: "Copy PNG", symbol: "doc.on.doc", run: copyImage),
            ShareAction(id: "savePNG", title: "Save PNG", symbol: "square.and.arrow.down", run: saveImage),
            ShareAction(id: "caption", title: "Caption", symbol: "text.quote") {
                caption = CaptionDraft(text: stampedCaption())
            },
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

        return VStack(spacing: MeterBarTheme.Spacing.sm) {
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

    /// `.bordered`, like every other button in the app. The overlay used to
    /// tint its first action prominent, which made the one control that is not
    /// a decision — copying a PNG — look like a form's default action, in a
    /// style nothing else on the page wears.
    private func button(_ action: ShareAction, iconOnly: Bool) -> some View {
        Button(action: action.run) {
            Label(action.title, systemImage: action.symbol)
                .labelStyle(ShareActionLabelStyle(iconOnly: iconOnly))
        }
        .buttonStyle(.bordered)
        .disabled(action.isDisabled)
        .help(action.title)
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

// MARK: - ShareCaptionSheet

/// The caption, on demand and editable.
///
/// Six cards on a page means six captions, and printed inline they were three
/// monospaced lines of text under every tile that nobody read and everybody
/// scrolled past. Behind a button they are out of the way; editable, they stop
/// pretending the generated wording is the wording you will post.
private struct ShareCaptionSheet: View {
    // MARK: Lifecycle

    init(title: String, subtitle: String, text: String, onCopy: @escaping (String) -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.onCopy = onCopy
        self._text = State(initialValue: text)
    }

    // MARK: Internal

    var body: some View {
        VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.xxs) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(MeterBarTheme.Spacing.sm)
                .frame(minWidth: 420, minHeight: 150)
                .meterBarCardSurface(cornerRadius: MeterBarTheme.Radius.medium)

            HStack {
                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button {
                    onCopy(text)
                    dismiss()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(MeterBarTheme.CardPadding.standard.value)
    }

    // MARK: Private

    private let title: String
    private let subtitle: String
    private let onCopy: (String) -> Void

    @State private var text: String
    @Environment(\.dismiss)
    private var dismiss
}
