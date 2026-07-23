import MeterBarShared
import SwiftUI

// MARK: - SettingsView

/// Shell for the compact, MacSweep-style settings window: a top tab bar over a
/// fixed-size window. Each tab is its own focused view (extracted from what was
/// a single 2k-line file); this shell only owns the `TabView`, the window
/// frame, and the per-tab scroll/padding wrapper.
struct SettingsView: View {
    // MARK: Internal

    var body: some View {
        settingsTabView
    }

    // MARK: Private

    // The Automation tab is feature-flagged, so the shell observes just this one
    // store; every other tab owns the shared singletons it needs.
    @StateObject private var sessionWakeStore = SessionWakeSettingsStore.shared

    /// Compact, MacSweep-style settings: a top tab bar over a fixed-size window
    /// instead of a sidebar. Each tab reuses the existing section builders.
    private var settingsTabView: some View {
        TabView {
            settingsTab {
                GeneralSettingsView()
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            settingsTab {
                ProviderSettingsView()
            }
            .tabItem { Label("Providers", systemImage: "square.grid.2x2") }

            settingsTab {
                WidgetSettingsView()
            }
            .tabItem { Label("Widget", systemImage: "rectangle.3.group") }

            settingsTab {
                ApiUsageSettingsView()
            }
            .tabItem { Label("API Usage", systemImage: "key") }

            settingsTab {
                CostSettingsView()
            }
            .tabItem { Label("Cost", systemImage: "chart.bar") }

            if sessionWakeStore.featureEnabled {
                settingsTab {
                    SessionWakeSettingsView()
                }
                .tabItem { Label("Automation", systemImage: "moon.zzz") }
            }

            settingsTab {
                AboutSettingsView()
            }
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: Self.windowWidth, height: Self.windowHeight)
        .background {
            // MeterBarDetailBackground now handles safe area internally (material
            // full-bleed, tint inset). The macOS TabView renders its tab strip as
            // a separate control rather than a scroll-under bar, so nothing here
            // scrolls beneath a bar — but this keeps the two windows consistent.
            MeterBarDetailBackground()
        }
    }

    // Compact, fixed window. Wide enough for the provider pane's account rows
    // and usage bars; content is pinned to a leading-aligned column so nothing
    // centers or clips at the window edges.
    private static let windowWidth: CGFloat = 760
    private static let windowHeight: CGFloat = 660

    /// Wraps a tab's content in a padded, scrollable, top-aligned column so
    /// long sections stay reachable in the compact fixed-height window.
    private func settingsTab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(.horizontal, MeterBarTheme.Spacing.xl)
            .padding(.vertical, MeterBarTheme.Spacing.xl)
            .frame(width: Self.windowWidth, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
    }
}
