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
    private var menuPanel: MeterBarMenuPanelController?
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

    /// Monotonic stamp for status-item updates: activity probes run off the
    /// main actor, so a stale in-flight result must not overwrite a newer one.
    private var statusItemUpdateGeneration = 0

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

        menuPanel = MeterBarMenuPanelController(
            statusButtonProvider: { [weak self] in
                self?.statusItem?.button
            },
            onDismiss: {
                MeterBarMenuDetailPanel.shared.dismiss()
                FirstRunOnboardingStore.shared.dismiss()
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
            observeUsageMetrics()
            // Bring the Session Wake watcher online: it re-arms if the toggle was
            // left on and starts/stops as the user flips it.
            SessionWakeController.shared.activate()
            // Surface a banner when a wake run finishes (gated by the global,
            // provider, and Session Wake notification switches).
            observeSessionWakeCompletion()
        }

        // Setup notifications (also handles initial data refresh)
        setupNotifications()
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

        let statusItem = NSMenuItem(title: "Status Pages", action: nil, keyEquivalent: "")
        statusItem.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)
        statusItem.submenu = makeProviderStatusMenu()
        menu.addItem(statusItem)

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

    private func makeProviderStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let monitor = ProviderStatusMonitor.shared

        if monitor.reports.isEmpty, !monitor.isRefreshing {
            Task {
                await monitor.refreshAllIfNeeded()
            }
        }

        for service in ServiceType.allCases {
            let item = NSMenuItem(
                title: providerStatusMenuTitle(for: service),
                action: nil,
                keyEquivalent: ""
            )
            item.image = statusDotImage(for: providerStatusMenuIndicator(for: service))
            item.submenu = makeProviderStatusSubmenu(for: service)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(
            title: "Refresh Status Pages",
            action: #selector(refreshProviderStatusesFromStatusMenu),
            keyEquivalent: ""
        )
        refreshItem.target = self
        refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshItem.isEnabled = !monitor.isRefreshing
        menu.addItem(refreshItem)

        return menu
    }

    private func makeProviderStatusSubmenu(for service: ServiceType) -> NSMenu {
        let menu = NSMenu()
        let monitor = ProviderStatusMonitor.shared

        if let report = monitor.reports[service] {
            let summaryItem = disabledMenuItem(
                title: report.summary.description ?? report.summary.indicator.summaryLabel,
                image: statusDotImage(for: report.summary.indicator)
            )
            menu.addItem(summaryItem)

            if !report.components.isEmpty {
                menu.addItem(.separator())
                for component in report.components {
                    menu.addItem(makeStatusComponentMenuItem(component))
                }
            }
        } else if let error = monitor.errors[service] {
            menu.addItem(disabledMenuItem(title: error, image: statusDotImage(for: .critical)))
        } else {
            menu.addItem(disabledMenuItem(title: "Checking status...", image: statusDotImage(for: .unknown)))
        }

        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: "Open \(service.statusPageDisplayName) Status Page",
            action: #selector(openProviderStatusPageFromStatusMenu(_:)),
            keyEquivalent: ""
        )
        openItem.target = self
        openItem.representedObject = service.rawValue
        openItem.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
        menu.addItem(openItem)

        return menu
    }

    private func makeStatusComponentMenuItem(_ component: ProviderStatusComponent) -> NSMenuItem {
        let item = NSMenuItem(
            title: "\(component.name)  \(component.statusLabel)",
            action: nil,
            keyEquivalent: ""
        )
        item.image = statusDotImage(for: component.indicator)

        if component.isGroup {
            let submenu = NSMenu()
            for child in component.children {
                submenu.addItem(makeStatusComponentMenuItem(child))
            }
            item.submenu = submenu
        } else {
            item.isEnabled = false
        }

        return item
    }

    private func providerStatusMenuTitle(for service: ServiceType) -> String {
        let monitor = ProviderStatusMonitor.shared
        if let report = monitor.reports[service] {
            let summary = report.summary.description ?? report.summary.indicator.summaryLabel
            return "\(service.statusPageDisplayName) — \(summary)"
        }
        if monitor.errors[service] != nil {
            return "\(service.statusPageDisplayName) — Unavailable"
        }
        return "\(service.statusPageDisplayName) — Checking..."
    }

    private func providerStatusMenuIndicator(for service: ServiceType) -> ProviderStatusIndicator {
        let monitor = ProviderStatusMonitor.shared
        if let report = monitor.reports[service] {
            return report.summary.indicator
        }
        if monitor.errors[service] != nil {
            return .critical
        }
        return .unknown
    }

    private func disabledMenuItem(title: String, image: NSImage? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = image
        item.isEnabled = false
        return item
    }

    private func statusDotImage(for indicator: ProviderStatusIndicator) -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        statusDotColor(for: indicator).setFill()
        NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 6, height: 6)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func statusDotColor(for indicator: ProviderStatusIndicator) -> NSColor {
        switch indicator {
        case .none:
            return .systemGreen
        case .minor, .maintenance:
            return .systemOrange
        case .major, .critical:
            return .systemRed
        case .unknown:
            return .tertiaryLabelColor
        }
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
        let currentMetrics = UsageDataManager.shared.metrics

        for service in ServiceType.allCases where service != .claudeCode && service != .codexCli {
            // Disabled providers are removed from UsageDataManager. Evaluate an
            // empty snapshot so their stale band keys are cleared instead of
            // suppressing a future crossing after the provider is re-enabled.
            let metrics = currentMetrics[service] ?? UsageMetrics(service: service, lastUpdated: now)
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

        keys = evaluateAccountNotifications(
            AccountNotificationInput(
                service: .claudeCode,
                accounts: ClaudeCodeAccountStore.shared.accounts.map { ($0.id, $0.name) },
                accountMetrics: UsageDataManager.shared.claudeCodeAccountMetrics,
                fallbackMetrics: currentMetrics[.claudeCode]
            ),
            decider: decider,
            keys: keys,
            now: now
        )
        keys = evaluateAccountNotifications(
            AccountNotificationInput(
                service: .codexCli,
                accounts: CodexAccountStore.shared.accounts.map { ($0.id, $0.name) },
                accountMetrics: UsageDataManager.shared.codexAccountMetrics,
                fallbackMetrics: currentMetrics[.codexCli]
            ),
            decider: decider,
            keys: keys,
            now: now
        )

        notifiedLimitKeys = keys
    }

    private struct AccountNotificationInput {
        let service: ServiceType
        let accounts: [(id: UUID, name: String)]
        let accountMetrics: [UUID: UsageMetrics]
        let fallbackMetrics: UsageMetrics?
    }

    private func evaluateAccountNotifications(
        _ input: AccountNotificationInput,
        decider: NotificationDecider,
        keys: Set<String>,
        now: Date
    ) -> Set<String> {
        var updatedKeys = keys
        let available = input.accounts.compactMap { account -> (UUID, String, UsageMetrics)? in
            guard let metrics = input.accountMetrics[account.id] else { return nil }
            return (account.id, account.name, metrics)
        }

        if available.isEmpty {
            let metrics = input.fallbackMetrics ?? UsageMetrics(service: input.service, lastUpdated: now)
            let evaluation = decider.evaluate(
                metrics: metrics,
                providerEnabled: providerVisibilityStore.isEnabled(input.service),
                alreadyNotified: updatedKeys,
                now: now
            )
            updatedKeys = evaluation.notifiedKeys
            evaluation.notifications.forEach(postNotification)
            return updatedKeys
        }

        for (id, name, metrics) in available {
            let evaluation = decider.evaluate(
                metrics: metrics,
                providerEnabled: providerVisibilityStore.isEnabled(input.service),
                alreadyNotified: updatedKeys,
                accountKey: id.uuidString,
                serviceDisplayName: "\(name) (\(input.service.displayName))",
                now: now
            )
            updatedKeys = evaluation.notifiedKeys
            evaluation.notifications.forEach(postNotification)
        }
        return updatedKeys
    }

    private func postNotification(_ fired: FiredNotification) {
        sendNotification(identifier: fired.key, title: fired.title, body: fired.body)
    }

    /// Observes the shared Session Wake status and posts a completion banner each
    /// time a run settles. The decision (gates + copy) lives in the pure,
    /// unit-tested `SessionWakeNotificationDecider`; this only turns a fired
    /// decision into a banner, mirroring `checkAndNotify`.
    @MainActor
    private func observeSessionWakeCompletion() {
        SessionWakeStatus.shared.$watcherState
            .sink { [weak self] state in
                guard case let .completed(summary) = state else { return }
                self?.postSessionWakeCompletion(summary: summary)
            }
            .store(in: &cancellables)
    }

    @MainActor
    private func postSessionWakeCompletion(summary: WakeRunSummary) {
        let context = SessionWakeNotificationContext(
            globalNotificationsEnabled: notificationPreferences.isEnabled,
            claudeProviderEnabled: providerVisibilityStore.isEnabled(.claudeCode),
            notifyOnCompletion: SessionWakeSettingsStore.shared.notifyOnCompletion
        )
        guard let fired = SessionWakeNotificationDecider.completionNotification(
            summary: summary,
            context: context
        ) else { return }
        sendNotification(identifier: fired.key, title: fired.title, body: fired.body)
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

        UsageDataManager.shared.$codexAccountMetrics
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateStatusItem(metrics: UsageDataManager.shared.metrics)
                }
            }
            .store(in: &cancellables)

        Publishers.Merge(
            ClaudeCodeAccountStore.shared.$customAccounts.map { _ in () },
            ClaudeCodeAccountStore.shared.$defaultAccountIsEnabled.map { _ in () }
        )
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateStatusItem(metrics: UsageDataManager.shared.metrics)
                }
            }
            .store(in: &cancellables)

        CodexAccountStore.shared.$customAccounts
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

        ProviderParseHealthStore.shared.$records
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateStatusItem(metrics: UsageDataManager.shared.metrics)
                }
            }
            .store(in: &cancellables)

        updateStatusItem(metrics: UsageDataManager.shared.metrics)
    }

    /// One menu-bar-title candidate whose on-disk activity probe has not run
    /// yet. The probe is a `@Sendable` closure so the filesystem scan can run
    /// off the main actor (it previously ran inline here and stalled the UI).
    private struct StatusLimitProbeRequest: Sendable {
        let key: String
        let displayName: String
        let limit: UsageLimit
        let probe: @Sendable () -> Date?
    }

    @MainActor
    private func updateStatusItem(metrics: [ServiceType: UsageMetrics]) {
        guard statusItem?.button != nil else { return }

        // Gather the cheap main-actor inputs now; run the activity probes
        // (directory scans) off the main actor; apply on return. A generation
        // counter lets a newer update supersede an in-flight probe.
        let requests = statusLimitProbeRequests(in: metrics)
        statusItemUpdateGeneration += 1
        let generation = statusItemUpdateGeneration

        Task { [weak self] in
            let candidates = await Task.detached(priority: .userInitiated) {
                requests.map { request in
                    StatusLimitCandidate(
                        key: request.key,
                        displayName: request.displayName,
                        limit: request.limit,
                        lastActivity: request.probe()
                    )
                }
            }.value
            guard let self, generation == self.statusItemUpdateGeneration else { return }
            self.applyStatusItemSelection(candidates: candidates)
        }
    }

    @MainActor
    private func applyStatusItemSelection(candidates: [StatusLimitCandidate]) {
        guard let button = statusItem?.button else { return }

        guard let selection = StatusItemLimitSelector.select(
            candidates: candidates,
            previousKey: shownStatusItemKey
        ) else {
            shownStatusItemKey = nil
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = "MeterBar"
            applyParseHealthAppearance(to: button)
            return
        }

        shownStatusItemKey = selection.key
        let percent = percentLeft(for: selection.limit)
        button.imagePosition = .imageLeft
        button.title = " \(percent)%"
        button.toolTip = "MeterBar: \(percent)% left on \(selection.displayName)"
        button.setAccessibilityLabel("MeterBar \(percent)% left on \(selection.displayName)")
        applyParseHealthAppearance(to: button)
    }

    @MainActor
    private func applyParseHealthAppearance(to button: NSStatusBarButton) {
        let now = Date()
        let hasAttention = providerVisibilityStore.enabledServices.contains { service in
            ProviderParseHealthStore.shared.records[service]?.needsAttention(now: now) == true
        }
        button.alphaValue = hasAttention ? 0.55 : 1
        if hasAttention {
            button.toolTip = "\(button.toolTip ?? "MeterBar") · Provider data needs attention"
        }
    }

    /// Every enabled account/provider quota that may own the menu bar title,
    /// each carrying a deferred probe for its latest on-disk activity so
    /// `StatusItemLimitSelector` can follow the accounts actually in use.
    @MainActor
    private func statusLimitProbeRequests(in metrics: [ServiceType: UsageMetrics]) -> [StatusLimitProbeRequest] {
        var requests: [StatusLimitProbeRequest] = []

        if providerVisibilityStore.isEnabled(.claudeCode) {
            for account in ClaudeCodeAccountStore.shared.enabledAccounts {
                guard let limit = claudeMetrics(for: account, metrics: metrics)?.sessionLimit else { continue }
                let configDirectory = account.configDirectory
                requests.append(StatusLimitProbeRequest(
                    key: "claude:\(account.id.uuidString)",
                    displayName: "\(account.name) (\(ServiceType.claudeCode.displayName))",
                    limit: limit,
                    probe: { AccountActivityInspector.claudeCodeActivity(configDirectory: configDirectory) }
                ))
            }
        }
        if providerVisibilityStore.isEnabled(.codexCli) {
            for account in CodexAccountStore.shared.accounts {
                let accountMetrics = UsageDataManager.shared.codexAccountMetrics[account.id]
                    ?? (account.isDefault ? metrics[.codexCli] : nil)
                guard let limit = accountMetrics?.sessionLimit else { continue }
                let homeDirectory = account.homeDirectory
                requests.append(StatusLimitProbeRequest(
                    key: "codex:\(account.id.uuidString)",
                    displayName: "\(account.name) (\(ServiceType.codexCli.displayName))",
                    limit: limit,
                    probe: { AccountActivityInspector.codexCliActivity(homeDirectory: homeDirectory) }
                ))
            }
        }
        if providerVisibilityStore.isEnabled(.cursor), let cursorLimit = metrics[.cursor]?.weeklyLimit {
            requests.append(StatusLimitProbeRequest(
                key: "cursor",
                displayName: ServiceType.cursor.displayName,
                limit: cursorLimit,
                probe: { AccountActivityInspector.cursorActivity() }
            ))
        }

        return requests
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
