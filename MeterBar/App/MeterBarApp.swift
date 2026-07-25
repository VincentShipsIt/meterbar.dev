import AppKit
import MeterBarShared
import Combine
import os
import SwiftUI

@main
struct MeterBarApp: App {
    @StateObject private var dataManager = UsageDataManager.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate

    init() {
        AppLog.app.info("MeterBar initializing")
    }

    var body: some Scene {
        Window("MeterBar", id: UsageDashboardWindowController.windowID) {
            UsageDashboardView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1040, height: 700)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        // A menu-bar app still needs one Scene; `SettingsView` is kept as its
        // content for the smoke test, but the standard Settings command below is
        // replaced so ⌘, / "Settings…" open the dashboard's in-window settings
        // mode instead of this separate window. No small settings window ever
        // shows.
        Settings {
            SettingsView()
        }
        .commands {
            MeterBarCommands()
        }
    }
}

private struct MeterBarCommands: Commands {
    @Environment(\.openWindow)
    private var openWindow

    var body: some Commands {
        UsageDashboardWindowController.shared.register(openWindow: openWindow)

        return CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                UsageDashboardWindowController.shared.showSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

/// App lifecycle and the menu-bar status item's plumbing.
///
/// The pieces this used to own inline now live next to it: the menu-bar drawing
/// in `MenuBarIconRenderer`, the right-click menu in `StatusMenuBuilder`, the
/// title selection in `StatusItemPresenter` (fed by `StatusLimitProbeRequests`),
/// the refresh fan-in in `StatusItemRefreshTrigger`, and the banners in
/// `UsageNotificationCoordinator`. What stays here is what genuinely belongs to
/// the delegate: activation policy, the status item itself, and the `@objc`
/// menu actions.
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var menuPanel: MeterBarMenuPanelController?
    private let dockVisibilityStore = DockVisibilityStore.shared
    private let notifications = UsageNotificationCoordinator()
    private var cancellables = Set<AnyCancellable>()

    /// Reads the button lazily: the status item does not exist until
    /// `applicationDidFinishLaunching`, and it can be torn down independently.
    private lazy var statusItemPresenter = StatusItemPresenter(
        statusButtonProvider: { [weak self] in
            self?.statusItem?.button
        }
    )

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Apply the persisted Dock visibility as early as possible so users who
        // hide MeterBar from the Dock don't see a brief Dock-icon flash.
        applyActivationPolicy(showInDock: dockVisibilityStore.showInDock)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.app.info("MeterBar finished launching")
        SoftwareUpdateController.shared.refreshState()

        // Keep Dock visibility in sync with the user's preference.
        observeDockVisibility()
        observeSystemWake()

        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else {
            AppLog.app.error("Failed to create status item button")
            return
        }

        // Set up the menu bar icon with 3 progress bars
        let image = MenuBarIconRenderer.meterIcon()
        image.isTemplate = true
        button.image = image

        button.action = #selector(handleStatusItemClick)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "MeterBar"
        button.imagePosition = .imageLeft
        button.font = .systemFont(ofSize: 14, weight: .semibold)

        menuPanel = MeterBarMenuPanelController(
            statusButtonProvider: { [weak self] in
                self?.statusItem?.button
            },
            onDismiss: {
                // Closing the popover only tears down the transient detail
                // panel. First-run onboarding is NOT dismissed here: an
                // incidental close (click-away / Escape) must leave the welcome
                // callout to reappear until the user acts on Enable / Not Now.
                MeterBarMenuDetailPanel.shared.dismiss()
            }
        )

        if FirstRunOnboardingStore.shared.shouldPresent {
            // Defer one run-loop turn so the status-item window is ready before
            // positioning the panel. This is the first-launch welcome moment.
            DispatchQueue.main.async { [weak self] in
                self?.menuPanel?.show()
            }
        }

        Task { @MainActor in
            observeStatusItemRefreshes()
            // Bring the Session Wake watcher online: it re-arms if the toggle was
            // left on and starts/stops as the user flips it.
            SessionWakeController.shared.activate()
            // The managed agent owns completion banners while it is available,
            // including when the GUI is quit. Development builds without the
            // embedded helper retain the in-app notification observer.
            if !SessionWakeController.shared.usesBackgroundAgent {
                notifications.observeSessionWakeCompletion()
            }
        }

        // Setup notifications (also handles initial data refresh)
        notifications.start()
        Task {
            await ProviderStatusMonitor.shared.refreshAllIfNeeded()
        }

        if CommandLine.arguments.contains("--open-dashboard") {
            UsageDashboardWindowController.shared.show()
        }
    }

    /// Left-click opens the popover; right-click (or control-click) opens a
    /// native menu so Quit stays reachable even when the Dock icon is hidden.
    @objc
    private func handleStatusItemClick() {
        let event = NSApp.currentEvent
        let isSecondaryClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)

        if isSecondaryClick {
            showStatusMenu()
        } else {
            togglePopover()
        }
    }

    @objc
    func togglePopover() {
        guard let menuPanel else { return }

        if menuPanel.isShown {
            menuPanel.dismiss()
        } else {
            menuPanel.show()
            // Opening the popover always pulls fresh data — providers read
            // local files, so this is cheap and the popover never shows a
            // stale snapshot from the last timer tick.
            Task { await UsageDataManager.shared.refreshAll() }
        }
    }

    /// Shows a native menu anchored to the menu bar icon. This is the always-on
    /// escape hatch for Quit (and Dock visibility), independent of the popover.
    private func showStatusMenu() {
        guard let button = statusItem?.button else { return }

        menuPanel?.dismiss()

        let menu = makeStatusMenu()
        let location = NSPoint(x: 0, y: button.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: button)
    }

    /// Builds the menu from a snapshot of `ProviderStatusMonitor`. The lazy
    /// first fetch stays on this side of the boundary: `StatusMenuBuilder` is
    /// pure so it can be tested, and building a menu should not start network
    /// work as a side effect.
    private func makeStatusMenu() -> NSMenu {
        let monitor = ProviderStatusMonitor.shared

        if monitor.reports.isEmpty, !monitor.isRefreshing {
            Task {
                await monitor.refreshAllIfNeeded()
            }
        }

        let builder = StatusMenuBuilder(
            target: self,
            actions: StatusMenuBuilder.Actions(
                toggleShowInDock: #selector(toggleShowInDock),
                openDashboard: #selector(openDashboardFromStatusMenu),
                refreshProviderStatuses: #selector(refreshProviderStatusesFromStatusMenu),
                openProviderStatusPage: #selector(openProviderStatusPageFromStatusMenu(_:)),
                quit: #selector(quitApp)
            ),
            showInDock: dockVisibilityStore.showInDock,
            status: StatusMenuBuilder.StatusSnapshot(
                reports: monitor.reports,
                errors: monitor.errors,
                isRefreshing: monitor.isRefreshing
            )
        )
        return builder.makeMenu()
    }

    @objc
    private func toggleShowInDock() {
        dockVisibilityStore.setShowInDock(!dockVisibilityStore.showInDock)
    }

    @objc
    private func openDashboardFromStatusMenu() {
        UsageDashboardWindowController.shared.show()
    }

    @objc
    private func refreshProviderStatusesFromStatusMenu() {
        Task {
            await ProviderStatusMonitor.shared.refreshAll()
        }
    }

    @objc
    private func openProviderStatusPageFromStatusMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let service = ServiceType(rawValue: rawValue),
              let url = service.statusPageURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc
    private func quitApp() {
        NSApp.terminate(nil)
    }

    /// Closing the dashboard window (or any window) should never quit MeterBar —
    /// it keeps running in the menu bar until the user explicitly quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon (when shown) with no open windows reopens the
    /// usage dashboard instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            UsageDashboardWindowController.shared.show()
        }
        return true
    }

    private func observeDockVisibility() {
        dockVisibilityStore.$showInDock
            .sink { [weak self] showInDock in
                Task { @MainActor in
                    self?.applyActivationPolicy(showInDock: showInDock)
                }
            }
            .store(in: &cancellables)
    }

    /// A repeating timer may be delayed while macOS sleeps. Forward one wake
    /// event to the usage manager, which owns cadence, freshness, and overlap
    /// policy and only refreshes when enabled data is stale.
    private func observeSystemWake() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { _ in
                Task { @MainActor in
                    await UsageDataManager.shared.refreshAfterWakeIfNeeded()
                }
            }
            .store(in: &cancellables)
    }

    /// One subscription in place of the eight identical `.sink`s this used to
    /// carry; the upstreams are enumerated in `StatusItemRefreshTrigger`. The
    /// stream replays on subscribe, which covers the trailing direct update the
    /// old `observeUsageMetrics()` ended with.
    @MainActor
    private func observeStatusItemRefreshes() {
        StatusItemRefreshTrigger.publisher()
            .sink { [weak self] _ in
                // `@Published` fires on `willSet`, so defer one main-actor hop
                // before reading the singleton back — otherwise the snapshot is
                // the pre-change one.
                Task { @MainActor in
                    self?.statusItemPresenter.update(metrics: UsageDataManager.shared.metrics)
                }
            }
            .store(in: &cancellables)
    }

    /// Shows or hides the Dock icon by switching the app's activation policy.
    /// The menu bar status item is unaffected and always remains visible.
    private func applyActivationPolicy(showInDock: Bool) {
        let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if showInDock {
            // Reassert foreground status so menus/windows behave after the
            // accessory -> regular transition.
            NSApp.activate(ignoringOtherApps: false)
        }
    }
}
