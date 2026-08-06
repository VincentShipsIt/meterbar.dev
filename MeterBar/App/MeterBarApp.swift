import AppKit
import MeterBarShared
import Combine
import os
import SwiftUI

/// Real entry point, so the release gate's `--launch-smoke` probe can answer
/// before SwiftUI (and therefore AppKit, the window server, and every shared
/// singleton) starts. `MeterBarApp.main()` never returns, so this stays the only
/// place either path is chosen.
@main
enum MeterBarMain {
    static func main() {
        LaunchSmokeProbe.exitIfRequested()
        MeterBarApp.main()
    }
}

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
    /// Live status items keyed by `MenuBarStatusItemDescriptor.id`. Merged mode
    /// keeps exactly one; per-provider mode owns one slot per tracked account.
    private var statusItems: [String: NSStatusItem] = [:]
    /// Descriptor ids in plan order, used to pick a stable fallback anchor.
    private var statusItemIDs: [String] = []
    /// The item the user last clicked, so the popover and the right-click menu
    /// open under that icon instead of always under the leftmost one.
    private var activeStatusItemID: String?
    private var menuPanel: MeterBarMenuPanelController?
    private let menuBarDisplayPreferences = MenuBarDisplayPreferencesStore.shared
    private let menuBarAccountSelection = MenuBarAccountSelectionStore.shared
    private let dockVisibilityStore = DockVisibilityStore.shared
    private let notifications = UsageNotificationCoordinator()
    private let quotaEvents = QuotaEventCoordinator.shared
    private var cancellables = Set<AnyCancellable>()

    /// Decides what each menu bar item shows and styles its button. Item
    /// lifecycle stays here; the presenter never creates or removes one.
    private lazy var statusItemPresenter = StatusItemPresenter(
        isPopoverOpen: { [weak self] in self?.menuPanel?.isShown ?? false },
        applyDescriptors: { [weak self] descriptors in
            self?.applyStatusItemDescriptors(descriptors)
        }
    )

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Apply the persisted Dock visibility as early as possible so users who
        // hide MeterBar from the Dock don't see a brief Dock-icon flash.
        applyActivationPolicy(showInDock: dockVisibilityStore.showInDock)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A quit that lands mid-refresh must not leave a `grok` agent behind:
        // the subprocess is spawned into its own process group precisely so it
        // can be reaped as a tree from here.
        GrokAgentProcess.terminateAll()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.app.info("MeterBar finished launching")
        SoftwareUpdateController.shared.refreshState()

        // Reconnect scripts are generated on demand and executed by Terminal;
        // sweep any the previous run left behind.
        ClaudeCodeReconnectService.purgeReconnectScripts()

        // Keep Dock visibility in sync with the user's preference.
        observeDockVisibility()
        observeSystemWake()

        // Create the initial menu bar item. The presentation plan takes over on
        // the first metrics update and may add or remove items from there.
        guard makeStatusItem(id: MenuBarStatusItemPlanner.mergedItemID) != nil else {
            AppLog.app.error("Failed to create status item button")
            return
        }
        statusItemIDs = [MenuBarStatusItemPlanner.mergedItemID]

        menuPanel = MeterBarMenuPanelController(
            statusButtonProvider: { [weak self] in
                self?.anchorStatusButton()
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
            // Watches the follow-focused-app opt-in; observes NSWorkspace only
            // while that preference is on (issue #341).
            FrontmostAppMonitor.shared.activate()
            // The managed agent owns completion banners while it is available,
            // including when the GUI is quit. Development builds without the
            // embedded helper retain the in-app notification observer.
            if !SessionWakeController.shared.usesBackgroundAgent {
                notifications.observeSessionWakeCompletion()
            }
        }

        // Prime and observe app-wide quota transitions before the notification
        // coordinator performs its launch refresh.
        quotaEvents.start()

        // Setup notifications (also handles initial data refresh)
        notifications.start()
        Task {
            await ProviderStatusMonitor.shared.refreshAllIfNeeded()
        }

        if CommandLine.arguments.contains("--open-dashboard") {
            UsageDashboardWindowController.shared.show()
        }
    }

    /// Creates one menu bar slot and wires its button. Returns nil when AppKit
    /// refuses the button, in which case the (useless) item is released again.
    @discardableResult
    private func makeStatusItem(id: String) -> NSStatusItem? {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Per-id autosave name so macOS restores each item's user-dragged
        // position separately instead of collapsing them onto one slot.
        item.autosaveName = "MeterBarStatusItem-\(id)"

        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return nil
        }

        button.image = statusItemPresenter.image(for: nil)
        button.action = #selector(handleStatusItemClick(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "MeterBar"
        button.imagePosition = .imageLeft
        button.font = .systemFont(ofSize: 14, weight: .semibold)

        statusItems[id] = item
        return item
    }

    /// Reconciles the live status items with the plan: drop the ones that are
    /// gone, create the ones that are new, restyle the rest in place. This is
    /// the delegate's half of the split — deciding *what* each item says is the
    /// presenter's, and it calls back in here to have the plan realized.
    private func applyStatusItemDescriptors(_ descriptors: [MenuBarStatusItemDescriptor]) {
        // A plan is allowed to be empty only as a bug. Keep the merged
        // placeholder alive so Quit / Settings stay reachable from the menu bar.
        let plan = descriptors.isEmpty
            ? [
                MenuBarStatusItemDescriptor(
                    id: MenuBarStatusItemPlanner.mergedItemID,
                    service: nil,
                    selectionKey: nil,
                    title: "",
                    tooltip: "MeterBar",
                    accessibilityLabel: "MeterBar",
                    visualStyle: StatusItemVisualStyle(fontSize: .standard, highContrast: false)
                )
            ]
            : descriptors
        let liveIDs = Set(plan.map(\.id))

        // Snapshot the keys: the loop mutates the dictionary it reads from.
        for id in Array(statusItems.keys) where !liveIDs.contains(id) {
            if let item = statusItems.removeValue(forKey: id) {
                NSStatusBar.system.removeStatusItem(item)
            }
        }

        if let activeStatusItemID, !liveIDs.contains(activeStatusItemID) {
            self.activeStatusItemID = nil
        }

        statusItemIDs = plan.map(\.id)

        for descriptor in plan {
            let item = statusItems[descriptor.id] ?? makeStatusItem(id: descriptor.id)
            guard let item, let button = item.button else { continue }
            // macOS can hide an autosaved item after a mode change; force it
            // back so Auto never leaves the user with a blank menu bar slot.
            item.isVisible = true
            if item.length <= 0 {
                item.length = NSStatusItem.variableLength
            }
            statusItemPresenter.apply(descriptor, to: button)
        }
    }

    /// Button the popover and menus attach to: the one just clicked, or the
    /// leftmost surviving item when nothing has been clicked yet.
    private func anchorStatusButton() -> NSStatusBarButton? {
        if let activeStatusItemID, let button = statusItems[activeStatusItemID]?.button {
            return button
        }
        return statusItemIDs.compactMap { statusItems[$0]?.button }.first
    }

    /// Left-click opens the popover; right-click (or control-click) opens a
    /// native menu so Quit stays reachable even when the Dock icon is hidden.
    @objc
    private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        // Remember which of the (possibly several) items was hit so the panel
        // and menu don't jump to a different icon than the one clicked.
        activeStatusItemID = statusItemIDs.first { statusItems[$0]?.button === sender }

        let event = NSApp.currentEvent
        let isSecondaryClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)

        if isSecondaryClick {
            showStatusMenu(from: sender)
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
            Task {
                await UsageDataManager.shared.refreshForExplicitAction(.popoverOpened)
            }
        }
    }

    /// Shows a native menu anchored to the menu bar icon. This is the always-on
    /// escape hatch for Quit (and Dock visibility), independent of the popover.
    private func showStatusMenu(from button: NSStatusBarButton) {
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
                selectMenuBarAuto: #selector(selectMenuBarAuto),
                selectMenuBarPin: #selector(selectMenuBarPin(_:)),
                selectMenuBarAllProviders: #selector(selectMenuBarAllProviders),
                selectMenuBarPerAccount: #selector(selectMenuBarPerAccount),
                selectMenuBarAccountSwitcher: #selector(selectMenuBarAccountSwitcher),
                selectMenuBarAccount: #selector(selectMenuBarAccount(_:)),
                toggleShowInDock: #selector(toggleShowInDock),
                openDashboard: #selector(openDashboardFromStatusMenu),
                refreshProviderStatuses: #selector(refreshProviderStatusesFromStatusMenu),
                openProviderStatusPage: #selector(openProviderStatusPageFromStatusMenu(_:)),
                quit: #selector(quitApp)
            ),
            showInDock: dockVisibilityStore.showInDock,
            menuBarShows: StatusMenuBuilder.MenuBarShowsSnapshot(
                mode: menuBarDisplayPreferences.presentationMode,
                pinnedKey: menuBarDisplayPreferences.pinnedCandidateKey,
                options: MenuBarStatusItemPlanner.switcherOptions(
                    for: statusItemPresenter.latestCandidates
                ),
                accounts: MenuBarAccountSwitcher.entries(
                    accounts: statusItemPresenter.menuBarAccounts(),
                    activeKey: statusItemPresenter.activeSwitcherAccountKey()
                )
            ),
            status: StatusMenuBuilder.StatusSnapshot(
                reports: monitor.reports,
                errors: monitor.errors,
                isRefreshing: monitor.isRefreshing
            )
        )
        return builder.makeMenu()
    }

    @objc
    private func selectMenuBarAuto() {
        menuBarDisplayPreferences.setPresentationMode(.merged)
        menuBarDisplayPreferences.setPinnedCandidateKey(nil)
    }

    @objc
    private func selectMenuBarPin(_ sender: NSMenuItem) {
        guard let pinKey = sender.representedObject as? String else { return }
        menuBarDisplayPreferences.setPresentationMode(.merged)
        menuBarDisplayPreferences.setPinnedCandidateKey(pinKey)
    }

    @objc
    private func selectMenuBarAllProviders() {
        menuBarDisplayPreferences.setPresentationMode(.perProvider)
    }

    @objc
    private func selectMenuBarPerAccount() {
        menuBarDisplayPreferences.setPresentationMode(.perAccount)
    }

    @objc
    private func selectMenuBarAccountSwitcher() {
        menuBarDisplayPreferences.setPresentationMode(.accountSwitcher)
    }

    @objc
    private func selectMenuBarAccount(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        menuBarAccountSelection.setMergedAccountKey(key)
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
