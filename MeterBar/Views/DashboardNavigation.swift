import AppKit
// ObservableObject / @Published came in transitively while the store lived in
// UsageDashboardView.swift; this file has to import Combine itself.
import Combine
import MeterBarShared
import SwiftUI

// Dashboard window controller, section enums, and the navigation store extracted
// from UsageDashboardView.swift (C1 split). Pure move, except for the
// `DashboardSection.refreshTarget` / `refreshesApiUsage` map and
// `SettingsSection.available(sessionWakeEnabled:)`, which lift logic that was
// inlined — and duplicated — inside the view body so it can be tested directly.

@MainActor
final class UsageDashboardWindowController {
    static let shared = UsageDashboardWindowController()
    static let windowID = "dashboard"

    private var openWindow: OpenWindowAction?
    private var shouldOpenWhenRegistered = false

    private init() {}

    func register(openWindow: OpenWindowAction) {
        self.openWindow = openWindow

        if shouldOpenWhenRegistered {
            shouldOpenWhenRegistered = false
            presentDashboard()
        }
    }

    func show(section: DashboardSection? = nil, focusedProviderID: String? = nil) {
        if let section {
            DashboardNavigationStore.shared.navigate(to: section, focusedProviderID: focusedProviderID)
        } else if let focusedProviderID {
            DashboardNavigationStore.shared.navigate(to: .limits, focusedProviderID: focusedProviderID)
        }

        presentDashboard()
    }

    /// Open (or front) the dashboard window in its in-window settings mode. This
    /// is what ⌘,, the app menu's "Settings…", and the popover's settings entry
    /// points now call — there is no separate Settings window.
    func showSettings(_ section: SettingsSection = .general) {
        DashboardNavigationStore.shared.openSettings(section)
        show()
    }

    private func presentDashboard() {
        guard let openWindow else {
            shouldOpenWhenRegistered = true
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: Self.windowID)
    }
}

enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case limits = "Limits"
    case status = "Status"
    case costs = "Costs"
    case optimize = "Optimize"
    case diagnostics = "Diagnostics"
    case share = "Share"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .overview:
            return "gauge.with.dots.needle.bottom.50percent"
        case .limits:
            return "chart.bar.fill"
        case .status:
            return "waveform.path.ecg"
        case .costs:
            return "dollarsign.circle.fill"
        case .optimize:
            return "leaf.fill"
        case .diagnostics:
            return "stethoscope"
        case .share:
            return "square.and.arrow.up.fill"
        }
    }

    /// Sidebar layout: frequency-ordered monitoring pages first, then health
    /// checks, then utilities. App settings live in the dedicated macOS
    /// Settings scene rather than masquerading as dashboard content.
    struct SidebarGroup: Identifiable {
        let title: String?
        let sections: [DashboardSection]

        var id: String { sections.first?.id ?? title ?? "" }
    }

    static let sidebarGroups: [SidebarGroup] = [
        SidebarGroup(title: nil, sections: [.overview, .limits, .costs, .optimize]),
        SidebarGroup(title: "Health", sections: [.status, .diagnostics]),
        SidebarGroup(title: "Utilities", sections: [.share]),
    ]

    var titlebarSubtitle: String {
        switch self {
        case .overview:
            return "Current health and local token history"
        case .limits:
            return "Every tracked quota window"
        case .status:
            return "Provider service health"
        case .costs:
            return "Local 30-day token spend"
        case .optimize:
            return "Where tokens go and how to trim them"
        case .diagnostics:
            return "Provider setup health"
        case .share:
            return "Social card export"
        }
    }

    /// What the toolbar's Refresh acts on for this page.
    enum RefreshTarget: Hashable {
        case providerStatus
        case costs
        case usage
    }

    /// Single source of truth for "what does Refresh do here". The spinner state,
    /// the Refresh action, and the missing-day cost top-up each encoded this map
    /// independently, so adding a page meant remembering three switch statements.
    var refreshTarget: RefreshTarget {
        switch self {
        case .status:
            return .providerStatus
        case .costs, .share, .optimize:
            return .costs
        case .overview, .limits, .diagnostics:
            return .usage
        }
    }

    /// Only the Costs page renders the org API-usage card, so it is the only page
    /// whose refresh also pulls the billing API.
    var refreshesApiUsage: Bool { self == .costs }
}

/// The app-settings pages, surfaced as an in-window mode of the dashboard rather
/// than a separate macOS Settings window. Mirrors the tabs the old `SettingsView`
/// shell carried, reusing the same section views. `.automation` is feature-gated
/// and only appears when Session Wake is enabled.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general = "General"
    case providers = "Providers"
    case widget = "Widget"
    case apiUsage = "API Usage"
    case cost = "Cost"
    case automation = "Automation"
    case about = "About"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .general: return "gearshape"
        case .providers: return "square.grid.2x2"
        case .widget: return "rectangle.3.group"
        case .apiUsage: return "key"
        case .cost: return "chart.bar"
        case .automation: return "moon.zzz"
        case .about: return "info.circle"
        }
    }

    /// Sections available right now — Automation only when Session Wake is
    /// enabled, matching the old settings shell's feature gate.
    static func available(sessionWakeEnabled: Bool) -> [SettingsSection] {
        allCases.filter { $0 != .automation || sessionWakeEnabled }
    }
}

/// A row in the settings sidebar. Providers used to be a second, horizontal
/// picker *inside* the Providers page — two navigation layers for one hierarchy.
/// They now share the sidebar's selection with the app's settings pages, so a
/// provider is one click from anywhere in settings.
enum SettingsSidebarItem: Hashable, Identifiable {
    case section(SettingsSection)
    case provider(ServiceType)

    var id: String {
        switch self {
        case let .section(section): return "section.\(section.id)"
        case let .provider(service): return "provider.\(service.id)"
        }
    }
}

/// Row composition for the settings sidebar. Pure so the ordering and
/// reachability rules are testable without hosting the view.
enum SettingsSidebarModel {
    /// The page that lists every supported provider with its tracking toggle.
    /// It sits at the foot of the Providers group rather than in the app-pages
    /// group, because it reads as "the rest of the providers".
    static let catalogPage: SettingsSection = .providers

    /// The app's own settings pages. Providers is excluded: it is surfaced as
    /// the "All Providers" row under the provider list instead.
    static var appPages: [SettingsSection] {
        SettingsSection.allCases.filter { $0 != catalogPage }
    }

    /// Provider rows for the sidebar: the *tracked* providers in display order.
    ///
    /// Driven by the enabled set rather than `ServiceType.allCases` on purpose.
    /// The old segmented picker rendered every case, so it degraded with each
    /// provider MeterBar added; this group only ever holds what the user
    /// actually tracks, and everything else stays reachable from All Providers.
    static func trackedProviders(enabledServices: Set<ServiceType>) -> [ServiceType] {
        enabledServices.sorted { $0.sortOrder < $1.sortOrder }
    }
}

@MainActor
final class DashboardNavigationStore: ObservableObject {
    static let shared = DashboardNavigationStore()

    @Published var selectedSection: DashboardSection = .overview
    @Published var focusedProviderID: ProviderSnapshot.ID?

    /// When true the dashboard swaps its sidebar + content for the settings
    /// pages (the gear next to Refresh, or ⌘,/Settings…). No separate window.
    @Published var isShowingSettings = false
    @Published var selectedSettingsSection: SettingsSection = .general

    /// The provider whose page is showing, when the sidebar selection is a
    /// provider row rather than a settings page. `nil` means the page in
    /// `selectedSettingsSection` is showing.
    @Published var selectedSettingsProvider: ServiceType?

    private init() {}

    /// The sidebar's current row — a provider outranks the page behind it.
    var settingsSidebarItem: SettingsSidebarItem {
        if let selectedSettingsProvider {
            return .provider(selectedSettingsProvider)
        }
        return .section(selectedSettingsSection)
    }

    func selectSettingsItem(_ item: SettingsSidebarItem) {
        switch item {
        case let .section(section):
            selectedSettingsSection = section
            selectedSettingsProvider = nil
        case let .provider(service):
            selectedSettingsProvider = service
        }
    }

    /// Keeps the sidebar selection valid when the tracked set changes — turning
    /// the selected provider off from its own page removes its row, so fall back
    /// to All Providers, which is where it can be turned back on.
    func settingsProvidersChanged(enabledServices: Set<ServiceType>) {
        guard let selectedSettingsProvider,
              !enabledServices.contains(selectedSettingsProvider) else { return }
        self.selectedSettingsProvider = nil
        selectedSettingsSection = SettingsSidebarModel.catalogPage
    }

    func navigate(to section: DashboardSection, focusedProviderID: ProviderSnapshot.ID? = nil) {
        selectedSection = section
        self.focusedProviderID = focusedProviderID
        isShowingSettings = false
    }

    /// Enter the in-window settings mode on `section` (defaults to General).
    func openSettings(_ section: SettingsSection = .general) {
        selectedSettingsSection = section
        selectedSettingsProvider = nil
        isShowingSettings = true
    }

    /// Return from settings to the monitoring dashboard.
    func closeSettings() {
        isShowingSettings = false
    }
}
