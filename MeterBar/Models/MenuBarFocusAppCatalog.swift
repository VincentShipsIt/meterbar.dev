import Foundation
import MeterBarShared

/// One app the user can map to a provider in Settings (issue #341).
nonisolated struct MenuBarFocusApp: Identifiable, Equatable, Sendable {
    let bundleID: String
    let displayName: String

    var id: String { bundleID }
}

/// The small, editable starting list of apps offered for focus mapping, and the
/// default mapping shipped with the feature.
///
/// The catalog is a convenience, not a whitelist: any app the user has already
/// mapped shows up in Settings whether or not it is listed here, and an app that
/// is listed but not installed simply never becomes frontmost.
nonisolated enum MenuBarFocusAppCatalog {
    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"

    /// Editors first, then terminals, matching the Settings row order.
    static let apps: [MenuBarFocusApp] = [
        MenuBarFocusApp(bundleID: cursorBundleID, displayName: "Cursor"),
        MenuBarFocusApp(bundleID: "com.microsoft.VSCode", displayName: "Visual Studio Code"),
        MenuBarFocusApp(bundleID: "com.exafunction.windsurf", displayName: "Windsurf"),
        MenuBarFocusApp(bundleID: "dev.zed.Zed", displayName: "Zed"),
        MenuBarFocusApp(bundleID: "com.apple.dt.Xcode", displayName: "Xcode"),
        MenuBarFocusApp(bundleID: "com.apple.Terminal", displayName: "Terminal"),
        MenuBarFocusApp(bundleID: "com.googlecode.iterm2", displayName: "iTerm2"),
        MenuBarFocusApp(bundleID: "com.mitchellh.ghostty", displayName: "Ghostty"),
        MenuBarFocusApp(bundleID: "dev.warp.Warp-Stable", displayName: "Warp"),
        MenuBarFocusApp(bundleID: "net.kovidgoyal.kitty", displayName: "kitty"),
        MenuBarFocusApp(bundleID: "org.alacritty", displayName: "Alacritty"),
        MenuBarFocusApp(bundleID: "com.github.wez.wezterm", displayName: "WezTerm")
    ]

    /// Apps that host a CLI rather than being one. Called out in Settings so the
    /// blank default reads as a deliberate choice, not an oversight.
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm"
    ]

    /// Only apps whose provider is unambiguous ship mapped. Terminals are left
    /// to the user on purpose: a terminal window says nothing about which CLI is
    /// running in it, and MeterBar does not look.
    static let defaultMapping: [String: ServiceType] = [cursorBundleID: .cursor]

    /// Settings rows: the catalog plus anything the user has already mapped,
    /// so a mapping never becomes invisible (and un-editable) just because the
    /// app is not one MeterBar knows by name.
    static func rows(for mapping: [String: ServiceType]) -> [MenuBarFocusApp] {
        let known = Set(apps.map(\.bundleID))
        let extras = mapping.keys
            .filter { !known.contains($0) }
            .sorted()
            .map { MenuBarFocusApp(bundleID: $0, displayName: $0) }
        return apps + extras
    }
}
