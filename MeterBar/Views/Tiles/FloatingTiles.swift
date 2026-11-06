import AppKit
import MeterBarShared
import SwiftUI
import WidgetKit

/// Owns the live provider stores and hands the current snapshots to its
/// content, so a surface outside the popover (a floating tile) draws exactly
/// what the popover draws.
struct LiveProviderSnapshotsReader<Content: View>: View {
    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var claudeCodeService = ClaudeCodeLocalService.shared
    @StateObject private var codexCliService = CodexCliLocalService.shared
    @StateObject private var codexAccountStore = CodexAccountStore.shared
    @StateObject private var grokAccountStore = GrokAccountStore.shared
    @StateObject private var openRouterAccountStore = OpenRouterAccountStore.shared
    @StateObject private var cursorService = CursorLocalService.shared
    @StateObject private var openRouterService = OpenRouterService.shared
    @StateObject private var grokService = GrokCLIUsageService.shared
    @StateObject private var claudeAccountStore = ClaudeCodeAccountStore.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var parseHealthStore = ProviderParseHealthStore.shared

    let content: ([ProviderSnapshot]) -> Content

    init(@ViewBuilder content: @escaping ([ProviderSnapshot]) -> Content) {
        self.content = content
    }

    var body: some View {
        content(snapshots)
    }

    private var snapshots: [ProviderSnapshot] {
        // Reads the shared stores this view observes through its @StateObjects.
        ProviderSnapshotBuilder.liveSnapshots()
    }
}

// MARK: - Floating tiles

/// The persisted list of tiles the user floated, in the order they floated
/// them. Kept apart from the panels so the rules are testable without AppKit
/// windows.
struct FloatingTileRegistry {
    static let defaultsKey = "floatingTiles.snapshotIDs"
    static let maximumCount = 6

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var ids: [String] {
        userDefaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    /// Adds `id` once. Returns false when it was already floating or the
    /// screen already holds the maximum number of tiles.
    @discardableResult
    func add(_ id: String) -> Bool {
        var current = ids
        guard !current.contains(id), current.count < Self.maximumCount else { return false }
        current.append(id)
        userDefaults.set(current, forKey: Self.defaultsKey)
        return true
    }

    func remove(_ id: String) {
        userDefaults.set(ids.filter { $0 != id }, forKey: Self.defaultsKey)
    }

    /// Where the nth new tile lands before the user drags it: stacked down the
    /// top-right corner of the visible screen.
    static func defaultOrigin(index: Int, tileSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        let margin: CGFloat = 16
        let step = tileSize.height + 10
        return CGPoint(
            x: visibleFrame.maxX - tileSize.width - margin,
            y: visibleFrame.maxY - margin - tileSize.height - CGFloat(index) * step
        )
    }
}

/// Always-on-top panels, one per floated tile. A tile stays until its close
/// button is pressed and comes back on the next launch, where the user left it.
@MainActor
final class FloatingTileController {
    static let shared = FloatingTileController()
    static let tileSize = CGSize(width: 232, height: 76)

    private let registry: FloatingTileRegistry
    private var panels: [String: NSPanel] = [:]

    init(registry: FloatingTileRegistry = FloatingTileRegistry()) {
        self.registry = registry
    }

    func float(snapshotID: String) {
        if let panel = panels[snapshotID] {
            panel.orderFrontRegardless()
            return
        }
        guard registry.add(snapshotID) || registry.ids.contains(snapshotID) else { return }
        present(snapshotID: snapshotID)
    }

    func close(snapshotID: String) {
        registry.remove(snapshotID)
        panels.removeValue(forKey: snapshotID)?.close()
    }

    /// Puts back every tile that was floating when the app last quit.
    func restore() {
        for id in registry.ids where panels[id] == nil {
            present(snapshotID: id)
        }
    }

    /// True when any part of `frame` lies on one of `screens`.
    static func isReachable(_ frame: CGRect, on screens: [CGRect]) -> Bool {
        screens.contains { $0.intersects(frame) }
    }

    private func present(snapshotID: String) {
        let panel = FloatingTilePanel(
            contentRect: CGRect(origin: .zero, size: Self.tileSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(
            rootView: FloatingTileView(snapshotID: snapshotID) { [weak self] in
                self?.close(snapshotID: snapshotID)
            }
        )

        let autosaveName = "MeterBarFloatingTile-\(snapshotID)"
        // A saved frame on a display that is no longer connected would leave the
        // tile unreachable but still counted toward the limit.
        let restored = panel.setFrameUsingName(autosaveName)
        if !restored || !Self.isReachable(panel.frame, on: NSScreen.screens.map(\.visibleFrame)) {
            let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
            let origin = FloatingTileRegistry.defaultOrigin(
                index: panels.count,
                tileSize: Self.tileSize,
                visibleFrame: visible
            )
            panel.setFrame(CGRect(origin: origin, size: Self.tileSize), display: false)
        }
        panel.setFrameAutosaveName(autosaveName)
        panel.orderFrontRegardless()
        panels[snapshotID] = panel
    }
}

private final class FloatingTilePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The floating panel's content: the tile, a close button on hover, and the
/// same right-click commands as the popover tile.
struct FloatingTileView: View {
    let snapshotID: String
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        LiveProviderSnapshotsReader { snapshots in
            ZStack(alignment: .topTrailing) {
                if let snapshot = snapshots.first(where: { $0.stableKey == snapshotID }) {
                    ProviderTile(snapshot: snapshot, style: .floating)
                        .contextMenu {
                            Button("Open in Dashboard") {
                                UsageDashboardWindowController.shared.show(
                                    section: .limits,
                                    focusedProviderID: snapshot.id
                                )
                            }
                            Button("Refresh") {
                                Task { await UsageDataManager.shared.refresh(service: snapshot.service) }
                            }
                            Divider()
                            Button("Close floating tile", action: onClose)
                        }
                } else {
                    DashboardTile(padding: .popover) {
                        Text("This provider is no longer enabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }

                if isHovering {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 16, height: 16)
                            .background(.thinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Close floating tile")
                    .accessibilityLabel("Close floating tile")
                }
            }
        }
        .environment(\.meterBarTileSurface, .glass)
        .frame(width: FloatingTileController.tileSize.width, height: FloatingTileController.tileSize.height)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Desktop widgets

/// macOS does not let an app place a widget on the desktop itself: the user
/// drags it out of the widget gallery. "Add to desktop" refreshes the widget
/// timelines so the gallery shows current numbers, then says exactly where the
/// Tiles widget is.
@MainActor
enum DesktopWidgetGuide {
    static let messageText = "Add MeterBar to your desktop"
    static let informativeText = """
        Right-click an empty spot on your desktop and choose Edit Widgets. \
        Search for MeterBar and drag the Tiles widget onto the desktop. \
        The small size shows your tightest limit; the medium size shows the tightest providers that fit.
        """

    /// Reloads the timelines first so the gallery shows current numbers, then
    /// shows the guide. The two steps are injectable so a test can pin that
    /// order without touching WidgetKit or opening a modal alert.
    static func present(
        reloadTimelines: () -> Void = reloadWidgetTimelines,
        showGuide: () -> Void = showAlert
    ) {
        reloadTimelines()
        showGuide()
    }

    static func reloadWidgetTimelines() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func showAlert() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
