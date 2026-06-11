import Combine
import SwiftUI
import UserNotifications

@main
struct MeterBarApp: App {
    @StateObject private var dataManager = UsageDataManager.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        print("═══════════════════════════════════════")
        print("🎯 MeterBar: App Initializing")
        print("═══════════════════════════════════════")
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
    private var cancellables = Set<AnyCancellable>()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 MeterBar: Application did finish launching")
        
        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let button = statusItem?.button else {
            print("❌ Failed to create status item button")
            return
        }
        
        // Set up the menu bar icon with 3 progress bars
        let image = createMenuBarIcon()
        image.isTemplate = true
        button.image = image
        
        button.action = #selector(togglePopover)
        button.target = self
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
    
    @objc func togglePopover() {
        guard let button = statusItem?.button,
              let popover = popover else { return }
        
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
                        print("Notification permission error: \(error)")
                    } else if !granted {
                        print("Notification permission denied by user")
                    }
                }
            case .denied:
                print("Notification permission was previously denied. User can enable in System Settings.")
            case .authorized, .provisional, .ephemeral:
                // Already authorized, no action needed
                break
            @unknown default:
                break
            }
        }
        
        // Monitor usage and send notifications
        Task {
            await monitorUsage()
        }
    }
    
    @MainActor
    private func monitorUsage() async {
        // Initial refresh on app launch
        await UsageDataManager.shared.refreshAll()

        // Check for approaching limits periodically
        // Note: UsageDataManager handles its own 15-minute auto-refresh
        // This loop just checks metrics for notification purposes
        while true {
            for (service, metrics) in UsageDataManager.shared.metrics where providerVisibilityStore.isEnabled(service) {
                checkAndNotify(metrics: metrics)
            }

            // Wait 5 minutes before next notification check
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
        }
    }
    
    private func checkAndNotify(metrics: UsageMetrics) {
        let limits = [metrics.sessionLimit, metrics.weeklyLimit, metrics.codeReviewLimit].compactMap { $0 }
        
        for limit in limits {
            if limit.percentage >= 90 && limit.percentage < 100 {
                sendNotification(
                    title: "\(metrics.service.displayName) Usage Warning",
                    body: "You're at \(Int(limit.percentage))% of your limit"
                )
            } else if limit.percentage >= 100 {
                sendNotification(
                    title: "\(metrics.service.displayName) Limit Reached",
                    body: "You've reached your usage limit"
                )
            }
        }
    }
    
    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
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

        guard let status = selectedStatus(in: metrics), let limit = status.limit else {
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = "MeterBar"
            return
        }

        let percent = percentLeft(for: limit)
        button.imagePosition = .imageLeft
        button.title = " \(percent)%"
        button.toolTip = "MeterBar: \(percent)% left · \(status.label)"
        button.setAccessibilityLabel("MeterBar \(percent)% left, \(status.label)")
    }

    @MainActor
    private func selectedStatus(in metrics: [ServiceType: UsageMetrics]) -> (label: String, limit: UsageLimit?)? {
        ("overview primary quota", mostConstrainedPrimaryLimit(in: metrics))
    }

    @MainActor
    private func mostConstrainedPrimaryLimit(in metrics: [ServiceType: UsageMetrics]) -> UsageLimit? {
        let claudeLimits = providerVisibilityStore.isEnabled(.claudeCode)
            ? ClaudeCodeAccountStore.shared.accounts.compactMap {
                claudeMetrics(for: $0, metrics: metrics)?.sessionLimit
            }
            : []

        var limits = claudeLimits
        if providerVisibilityStore.isEnabled(.codexCli), let codexLimit = metrics[.codexCli]?.sessionLimit {
            limits.append(codexLimit)
        }
        if providerVisibilityStore.isEnabled(.cursor), let cursorLimit = metrics[.cursor]?.weeklyLimit {
            limits.append(cursorLimit)
        }

        return limits.min { lhs, rhs in
            percentLeft(for: lhs) < percentLeft(for: rhs)
        }
    }

    @MainActor
    private func claudeMetrics(for account: ClaudeCodeAccount, metrics: [ServiceType: UsageMetrics]) -> UsageMetrics? {
        UsageDataManager.shared.claudeCodeAccountMetrics[account.id] ?? (account.isDefault ? metrics[.claudeCode] : nil)
    }

    private func percentLeft(for limit: UsageLimit) -> Int {
        guard limit.total > 0 else { return 100 }
        let rawPercentage = max(0, (limit.used / limit.total) * 100)
        return Int(max(0, 100 - rawPercentage).rounded())
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
