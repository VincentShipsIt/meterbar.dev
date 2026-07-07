import AppKit
import MeterBarShared
import Combine
import os
import SwiftUI
import UserNotifications

@main
struct MeterBarApp: App {
    @StateObject private var dataManager = UsageDataManager.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate

    init() {
        AppLog.app.info("MeterBar initializing")
    }

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let providerVisibilityStore = ProviderVisibilityStore.shared
    private let dockVisibilityStore = DockVisibilityStore.shared
    private let notificationPreferences = NotificationPreferencesStore.shared
    private var cancellables = Set<AnyCancellable>()
    private var monitorTask: Task<Void, Never>?

    /// Tracks which (service, limit, level) notifications have already fired so
    /// the 5-minute monitor loop doesn't re-alert every cycle while usage stays
    /// above a threshold. Keys are cleared when usage drops back below.
    private var notifiedLimitKeys: Set<String> = []

    /// The account whose quota the menu bar title currently shows; feeds the
    /// sticky selection so concurrent Claude + Codex use doesn't flip the title.
    private var shownStatusItemKey: String?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Apply the persisted Dock visibility as early as possible so users who
        // hide MeterBar from the Dock don't see a brief Dock-icon flash.
        applyActivationPolicy(showInDock: dockVisibilityStore.showInDock)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.app.info("MeterBar finished launching")

        // Keep Dock visibility in sync with the user's preference.
        observeDockVisibility()

        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else {
            AppLog.app.error("Failed to create status item button")
            return
        }

        // Set up the menu bar icon with 3 progress bars
        let image = createMenuBarIcon()
        image.isTemplate = true
        button.image = image

        button.action = #selector(handleStatusItemClick)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "MeterBar"
        button.imagePosition = .imageLeft
        button.font = .systemFont(ofSize: 14, weight: .semibold)

        // Create popover
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 520, height: 420)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(
            rootView: MenuBarView { [weak self] size in
                self?.popover?.contentSize = size
            }
        )

        Task { @MainActor in
            observeUsageMetrics()
        }

        // Setup notifications (also handles initial data refresh)
        setupNotifications()
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
        guard let button = statusItem?.button,
              let popover = popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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

        if popover?.isShown == true {
            popover?.performClose(nil)
        }

        let menu = makeStatusMenu()
        let location = NSPoint(x: 0, y: button.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: button)
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()

        let dockItem = NSMenuItem(
            title: "Show in Dock",
            action: #selector(toggleShowInDock),
            keyEquivalent: ""
        )
        dockItem.target = self
        dockItem.state = dockVisibilityStore.showInDock ? .on : .off
        menu.addItem(dockItem)

        let dashboardItem = NSMenuItem(
            title: "Open Usage Dashboard",
            action: #selector(openDashboardFromStatusMenu),
            keyEquivalent: ""
        )
        dashboardItem.target = self
        menu.addItem(dashboardItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit MeterBar",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
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

    private func setupNotifications() {
        // Check current authorization status first
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                // Request permission only if not yet determined
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error = error {
                        AppLog.app.error(
                            "Notification permission error: \(error.localizedDescription, privacy: .public)"
                        )
                    } else if !granted {
                        AppLog.app.info("Notification permission denied by user")
                    }
                }
            case .denied:
                AppLog.app.info("Notification permission previously denied; user can enable it in System Settings.")
            case .authorized, .provisional, .ephemeral:
                // Already authorized, no action needed
                break
            @unknown default:
                break
            }
        }

        // Monitor usage and send notifications. Store the task so it can be
        // cancelled, and so it isn't an orphaned unstructured Task.
        monitorTask?.cancel()
        monitorTask = Task { @MainActor [weak self] in
            await self?.monitorUsage()
        }
    }

    @MainActor
    private func monitorUsage() async {
        // Initial refresh on app launch
        await UsageDataManager.shared.refreshAll()

        // Check for approaching limits periodically.
        // Note: UsageDataManager handles its own auto-refresh; this loop only
        // checks metrics for notification purposes.
        while !Task.isCancelled {
            checkAndNotify()

            // Wait 5 minutes before next notification check. A thrown
            // CancellationError exits the loop instead of busy-looping.
            do {
                try await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            } catch {
                break
            }
        }
    }

    /// Evaluates every tracked service's metrics against the user's notification
    /// preferences and posts any warning/critical crossings. All decision logic
    /// lives in the pure, unit-tested `NotificationDecider`; this method only
    /// threads the dedup key set and turns fired decisions into banners.
    private func checkAndNotify() {
        let decider = NotificationDecider(preferences: notificationPreferences.preferences)
        let now = Date()
        var keys = notifiedLimitKeys

        for (service, metrics) in UsageDataManager.shared.metrics {
            let evaluation = decider.evaluate(
                metrics: metrics,
                providerEnabled: providerVisibilityStore.isEnabled(service),
                alreadyNotified: keys,
                now: now
            )
            keys = evaluation.notifiedKeys
            for fired in evaluation.notifications {
                postNotification(fired)
            }
        }

        notifiedLimitKeys = keys
    }

    private func postNotification(_ fired: FiredNotification) {
        let title: String
        let body: String
        switch fired.level {
        case .warning:
            title = "\(fired.serviceDisplayName) Usage Warning"
            body = "You're at \(fired.percentUsed)% of your limit"
        case .critical:
            title = "\(fired.serviceDisplayName) Limit Reached"
            body = "You've reached your usage limit"
        }
        sendNotification(identifier: fired.key, title: title, body: body)
    }

    private func sendNotification(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // Stable identifier: re-posting the same id replaces the pending request
        // rather than stacking a new banner every check.
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    @MainActor
    private func observeUsageMetrics() {
        UsageDataManager.shared.$metrics
            .sink { [weak self] metrics in
                Task { @MainActor in
                    self?.updateStatusItem(metrics: metrics)
                }
            }
            .store(in: &cancellables)

        UsageDataManager.shared.$claudeCodeAccountMetrics
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateStatusItem(metrics: UsageDataManager.shared.metrics)
                }
            }
            .store(in: &cancellables)

        ClaudeCodeAccountStore.shared.$customAccounts
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateStatusItem(metrics: UsageDataManager.shared.metrics)
                }
            }
            .store(in: &cancellables)

        ProviderVisibilityStore.shared.$hiddenServices
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateStatusItem(metrics: UsageDataManager.shared.metrics)
                }
            }
            .store(in: &cancellables)

        updateStatusItem(metrics: UsageDataManager.shared.metrics)
    }

    @MainActor
    private func updateStatusItem(metrics: [ServiceType: UsageMetrics]) {
        guard let button = statusItem?.button else { return }

        guard let selection = StatusItemLimitSelector.select(
            candidates: statusLimitCandidates(in: metrics),
            previousKey: shownStatusItemKey
        ) else {
            shownStatusItemKey = nil
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = "MeterBar"
            return
        }

        shownStatusItemKey = selection.key
        let percent = percentLeft(for: selection.limit)
        button.imagePosition = .imageLeft
        button.title = " \(percent)%"
        button.toolTip = "MeterBar: \(percent)% left on \(selection.displayName)"
        button.setAccessibilityLabel("MeterBar \(percent)% left on \(selection.displayName)")
    }

    /// Every enabled account/provider quota that may own the menu bar title,
    /// tagged with its latest on-disk activity so `StatusItemLimitSelector`
    /// can follow the accounts actually in use.
    @MainActor
    private func statusLimitCandidates(in metrics: [ServiceType: UsageMetrics]) -> [StatusLimitCandidate] {
        var candidates: [StatusLimitCandidate] = []

        if providerVisibilityStore.isEnabled(.claudeCode) {
            for account in ClaudeCodeAccountStore.shared.accounts {
                guard let limit = claudeMetrics(for: account, metrics: metrics)?.sessionLimit else { continue }
                candidates.append(StatusLimitCandidate(
                    key: "claude:\(account.id.uuidString)",
                    displayName: "\(account.name) (\(ServiceType.claudeCode.displayName))",
                    limit: limit,
                    lastActivity: AccountActivityInspector.claudeCodeActivity(
                        configDirectory: account.configDirectory
                    )
                ))
            }
        }
        if providerVisibilityStore.isEnabled(.codexCli), let codexLimit = metrics[.codexCli]?.sessionLimit {
            candidates.append(StatusLimitCandidate(
                key: "codex",
                displayName: ServiceType.codexCli.displayName,
                limit: codexLimit,
                lastActivity: AccountActivityInspector.codexCliActivity()
            ))
        }
        if providerVisibilityStore.isEnabled(.cursor), let cursorLimit = metrics[.cursor]?.weeklyLimit {
            candidates.append(StatusLimitCandidate(
                key: "cursor",
                displayName: ServiceType.cursor.displayName,
                limit: cursorLimit,
                lastActivity: AccountActivityInspector.cursorActivity()
            ))
        }

        return candidates
    }

    @MainActor
    private func claudeMetrics(for account: ClaudeCodeAccount, metrics: [ServiceType: UsageMetrics]) -> UsageMetrics? {
        UsageDataManager.shared.claudeCodeAccountMetrics[account.id] ?? (account.isDefault ? metrics[.claudeCode] : nil)
    }

    private func percentLeft(for limit: UsageLimit) -> Int {
        // Shared math so the menu-bar title always agrees with the popover and
        // dashboard (the previous copy rounded instead of ceiling and could
        // disagree by 1%).
        QuotaMath.percentLeft(for: limit)
    }

    private func createMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let barHeight: CGFloat = 3
            let barSpacing: CGFloat = 2
            let cornerRadius: CGFloat = 1.5

            // Three bars with different widths (like progress indicators)
            let barWidths: [CGFloat] = [0.35, 0.55, 0.85] // 35%, 55%, 85%
            let totalBarsHeight = (barHeight * 3) + (barSpacing * 2)
            let startY = (rect.height - totalBarsHeight) / 2

            for (index, fillPercent) in barWidths.enumerated() {
                let y = startY + CGFloat(index) * (barHeight + barSpacing)
                let barWidth = rect.width * fillPercent

                let barRect = NSRect(x: 0, y: y, width: barWidth, height: barHeight)
                let path = NSBezierPath(roundedRect: barRect, xRadius: cornerRadius, yRadius: cornerRadius)
                NSColor.black.setFill()
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
