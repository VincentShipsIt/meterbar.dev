import AppKit
import MeterBarShared

/// Builds the right-click status menu, extracted from `MeterBarApp.swift`
/// (C1 split).
///
/// Behaviour-preserving with one deliberate change: the builder reads a plain
/// `StatusSnapshot` value instead of `ProviderStatusMonitor.shared`, so menu
/// structure and titles are testable without touching the live monitor. The
/// caller passes the snapshot; the `refreshAllIfNeeded()` side-effect kick that
/// used to sit inside `makeProviderStatusMenu()` stays in `AppDelegate`, since
/// building a menu should not start network work.
struct StatusMenuBuilder {
    /// Selectors invoked on `target`. Passed in so the builder never needs to
    /// know about `AppDelegate`.
    struct Actions {
        let toggleShowInDock: Selector
        let openDashboard: Selector
        let refreshProviderStatuses: Selector
        let openProviderStatusPage: Selector
        let quit: Selector
    }

    /// The provider-status state the menu renders, copied out of
    /// `ProviderStatusMonitor` at build time.
    struct StatusSnapshot {
        var reports: [ServiceType: ProviderStatusReport] = [:]
        var errors: [ServiceType: String] = [:]
        var isRefreshing = false
    }

    let target: AnyObject?
    let actions: Actions
    let showInDock: Bool
    let status: StatusSnapshot

    func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let dockItem = NSMenuItem(
            title: "Show in Dock",
            action: actions.toggleShowInDock,
            keyEquivalent: ""
        )
        dockItem.target = target
        dockItem.state = showInDock ? .on : .off
        menu.addItem(dockItem)

        let dashboardItem = NSMenuItem(
            title: "Open Usage Dashboard",
            action: actions.openDashboard,
            keyEquivalent: ""
        )
        dashboardItem.target = target
        menu.addItem(dashboardItem)

        let statusItem = NSMenuItem(title: "Status Pages", action: nil, keyEquivalent: "")
        statusItem.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)
        statusItem.submenu = makeProviderStatusMenu()
        menu.addItem(statusItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit MeterBar",
            action: actions.quit,
            keyEquivalent: "q"
        )
        quitItem.target = target
        menu.addItem(quitItem)

        return menu
    }

    func makeProviderStatusMenu() -> NSMenu {
        let menu = NSMenu()

        for service in ServiceType.allCases {
            let item = NSMenuItem(
                title: Self.providerStatusMenuTitle(for: service, status: status),
                action: nil,
                keyEquivalent: ""
            )
            item.image = MenuBarIconRenderer.statusDot(
                for: Self.providerStatusMenuIndicator(for: service, status: status)
            )
            item.submenu = makeProviderStatusSubmenu(for: service)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(
            title: "Refresh Status Pages",
            action: actions.refreshProviderStatuses,
            keyEquivalent: ""
        )
        refreshItem.target = target
        refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshItem.isEnabled = !status.isRefreshing
        menu.addItem(refreshItem)

        return menu
    }

    func makeProviderStatusSubmenu(for service: ServiceType) -> NSMenu {
        let menu = NSMenu()

        if let report = status.reports[service] {
            let summaryItem = Self.disabledMenuItem(
                title: report.summary.description ?? report.summary.indicator.summaryLabel,
                image: MenuBarIconRenderer.statusDot(for: report.summary.indicator)
            )
            menu.addItem(summaryItem)

            if !report.components.isEmpty {
                menu.addItem(.separator())
                for component in report.components {
                    menu.addItem(Self.makeStatusComponentMenuItem(component))
                }
            }
        } else if let error = status.errors[service] {
            menu.addItem(Self.disabledMenuItem(
                title: error,
                image: MenuBarIconRenderer.statusDot(for: .critical)
            ))
        } else {
            menu.addItem(Self.disabledMenuItem(
                title: "Checking status...",
                image: MenuBarIconRenderer.statusDot(for: .unknown)
            ))
        }

        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: "Open \(service.statusPageDisplayName) Status Page",
            action: actions.openProviderStatusPage,
            keyEquivalent: ""
        )
        openItem.target = target
        openItem.representedObject = service.rawValue
        openItem.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
        menu.addItem(openItem)

        return menu
    }

    static func makeStatusComponentMenuItem(_ component: ProviderStatusComponent) -> NSMenuItem {
        let item = NSMenuItem(
            title: "\(component.name)  \(component.statusLabel)",
            action: nil,
            keyEquivalent: ""
        )
        item.image = MenuBarIconRenderer.statusDot(for: component.indicator)

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

    static func providerStatusMenuTitle(for service: ServiceType, status: StatusSnapshot) -> String {
        if let report = status.reports[service] {
            let summary = report.summary.description ?? report.summary.indicator.summaryLabel
            return "\(service.statusPageDisplayName) — \(summary)"
        }
        if status.errors[service] != nil {
            return "\(service.statusPageDisplayName) — Unavailable"
        }
        return "\(service.statusPageDisplayName) — Checking..."
    }

    static func providerStatusMenuIndicator(
        for service: ServiceType,
        status: StatusSnapshot
    ) -> ProviderStatusIndicator {
        if let report = status.reports[service] {
            return report.summary.indicator
        }
        if status.errors[service] != nil {
            return .critical
        }
        return .unknown
    }

    static func disabledMenuItem(title: String, image: NSImage? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = image
        item.isEnabled = false
        return item
    }
}
