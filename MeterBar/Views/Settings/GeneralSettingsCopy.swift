import Foundation

// MARK: - GeneralSettingsCopy

/// The General pane's load-bearing row copy, lifted out of the view so tests can
/// assert on it directly.
///
/// These five details are the ones that carry a constraint a user cannot infer
/// from the control: the per-account item cap, the fact that pinning and focus
/// following are mutually exclusive, that rotation stops while the popover is
/// open, and that focus following never asks for accessibility access. They were
/// each four to six sentences long, which was survivable only because the row's
/// label column was a fixed 190pt and nobody noticed the wrap. Shortening them
/// is fine; dropping one of those facts is not — that is what the tests in
/// `SettingsRowLayoutTests` are for.
enum GeneralSettingsCopy {
    static let autoRefreshInterval = "Adaptive stays between 1 and 30 minutes, "
        + "reacting to recent activity, quota movement, battery, and thermal state."

    static let menuBarShows = "Auto follows recent activity. "
        + "Pinning locks one provider, account, and quota window, and turns off focus following and rotation."

    static let rotateProviders = "Cycle the single item through providers that have data. "
        + "Rotation pauses while the popover is open, and a critical quota holds the item until it recovers."

    static let followFocusedApp = "Show the provider mapped to your frontmost app, "
        + "matched on its bundle identifier alone — no accessibility permission, window titles, or contents. "
        + "Turning this on clears the pin and rotation; either one turns it back off."

    /// `itemLimit` is `MenuBarAccountSelection.itemLimit` — the cap on how many
    /// account items One Per Account will create.
    static func menuBarLayout(itemLimit: Int) -> String {
        "One item, one per provider, or one per selected account (up to \(itemLimit)). "
            + "One Account With Switcher shows a single item you repoint from its right-click menu."
    }
}
