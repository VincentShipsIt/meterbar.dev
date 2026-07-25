import Foundation
import MeterBarShared

// MARK: - MenuBarAccountItemEntry

/// One account-scoped status item the menu bar should own.
///
/// This is the *account* half of the menu bar plan: it decides which accounts
/// get an item at all. What each item then says is decided by
/// `MenuBarStatusItemPlanner`, which consumes these entries.
nonisolated struct MenuBarAccountItemEntry: Equatable, Identifiable, Sendable {
    // MARK: Internal

    /// The legacy item: no account scope, competes across every candidate. It
    /// reuses the merged item's identity so falling back to it keeps the same
    /// menu-bar slot — and the presenter's hysteresis — instead of respawning.
    static let aggregate = MenuBarAccountItemEntry(
        id: MenuBarStatusItemPlanner.mergedItemID,
        accountKey: nil,
        displayName: "",
        badge: "",
        showsAccountSwitcher: false
    )

    let id: String
    /// nil for the aggregate item; otherwise the account this item is scoped to.
    let accountKey: String?
    /// Sanitized account name (empty for the aggregate item).
    let displayName: String
    /// Distinguishing affordance prefixed onto the item's title.
    let badge: String
    /// Whether this item's right-click menu offers the account switcher.
    let showsAccountSwitcher: Bool
}

// MARK: - MenuBarAccountItemPlan

nonisolated struct MenuBarAccountItemPlan: Equatable, Sendable {
    let mode: MenuBarPresentationMode
    let entries: [MenuBarAccountItemEntry]

    /// The plan every non-account mode uses: one unscoped item.
    static func aggregate(mode: MenuBarPresentationMode) -> MenuBarAccountItemPlan {
        MenuBarAccountItemPlan(mode: mode, entries: [.aggregate])
    }

    var itemIDs: [String] { entries.map(\.id) }
}

// MARK: - MenuBarAccountItemPlanner

/// Turns a presentation mode plus a persisted account selection into the set of
/// account-scoped status items the app should own (issue #266).
nonisolated enum MenuBarAccountItemPlanner {
    /// Menu-bar width is finite and shared with every other app's items, and
    /// macOS silently hides items that no longer fit. Four is deliberately
    /// conservative: it covers the common "work + personal, Claude + Codex"
    /// setup while still fitting a laptop-width menu bar.
    static let maximumConcurrentItems = 4

    static func plan(
        mode: MenuBarPresentationMode,
        selectedAccountKeys: [String],
        mergedAccountKey: String?,
        accounts: [MenuBarAccountIdentity]
    ) -> MenuBarAccountItemPlan {
        switch mode {
        case .merged, .perProvider:
            // Neither mode is account-scoped: the provider-level planner owns
            // the whole layout, so a single unscoped entry is all it needs.
            MenuBarAccountItemPlan.aggregate(mode: mode)
        case .perAccount:
            perAccountPlan(selectedAccountKeys: selectedAccountKeys, accounts: accounts)
        case .accountSwitcher:
            switcherPlan(mergedAccountKey: mergedAccountKey, accounts: accounts)
        }
    }

    // MARK: Private

    private static func perAccountPlan(
        selectedAccountKeys: [String],
        accounts: [MenuBarAccountIdentity]
    ) -> MenuBarAccountItemPlan {
        let enabled = accounts.filter(\.isEnabled)
        let entries = selectedAccountKeys
            .compactMap { key in enabled.first { $0.key == key } }
            .prefix(maximumConcurrentItems)
            .map { identity in
                MenuBarAccountItemEntry(
                    id: identity.key,
                    accountKey: identity.key,
                    displayName: identity.displayName,
                    badge: identity.badge,
                    showsAccountSwitcher: false
                )
            }
        // Every selected account being disabled or removed must not leave the
        // user without a menu bar, so fall back to the legacy aggregate item.
        guard !entries.isEmpty else {
            return MenuBarAccountItemPlan.aggregate(mode: .perAccount)
        }
        return MenuBarAccountItemPlan(mode: .perAccount, entries: entries)
    }

    private static func switcherPlan(
        mergedAccountKey: String?,
        accounts: [MenuBarAccountIdentity]
    ) -> MenuBarAccountItemPlan {
        let enabled = accounts.filter(\.isEnabled)
        let active = mergedAccountKey.flatMap { key in enabled.first { $0.key == key } } ?? enabled.first
        guard let active else {
            return MenuBarAccountItemPlan.aggregate(mode: .accountSwitcher)
        }
        return MenuBarAccountItemPlan(mode: .accountSwitcher, entries: [
            MenuBarAccountItemEntry(
                id: MenuBarStatusItemPlanner.mergedItemID,
                accountKey: active.key,
                displayName: active.displayName,
                badge: active.badge,
                showsAccountSwitcher: true
            )
        ])
    }
}

// MARK: - MenuBarAccountSwitcherEntry

nonisolated struct MenuBarAccountSwitcherEntry: Equatable, Identifiable, Sendable {
    let key: String
    let title: String
    let badge: String
    let isEnabled: Bool
    let isActive: Bool

    var id: String { key }
}

// MARK: - MenuBarAccountSwitcher

/// The switcher item's in-menu account list.
nonisolated enum MenuBarAccountSwitcher {
    /// Every tracked account, disabled ones included, so the menu can explain
    /// why an account holds no status item instead of silently omitting it.
    static func entries(
        accounts: [MenuBarAccountIdentity],
        activeKey: String?
    ) -> [MenuBarAccountSwitcherEntry] {
        accounts.map { identity in
            MenuBarAccountSwitcherEntry(
                key: identity.key,
                title: identity.displayName,
                badge: identity.badge,
                isEnabled: identity.isEnabled,
                isActive: identity.key == activeKey
            )
        }
    }

    /// Next enabled account after `activeKey`, wrapping around.
    static func nextKey(after activeKey: String?, accounts: [MenuBarAccountIdentity]) -> String? {
        let enabled = accounts.filter(\.isEnabled)
        guard !enabled.isEmpty else { return nil }
        guard let activeKey, let index = enabled.firstIndex(where: { $0.key == activeKey }) else {
            return enabled.first?.key
        }
        return enabled[(index + 1) % enabled.count].key
    }
}

// MARK: - MenuBarAccountCandidateFilter

/// Scopes the shared candidate set to the account one status item represents.
nonisolated enum MenuBarAccountCandidateFilter {
    static func candidates(
        for entry: MenuBarAccountItemEntry,
        in candidates: [StatusLimitCandidate]
    ) -> [StatusLimitCandidate] {
        guard let accountKey = entry.accountKey else { return candidates }
        return candidates.filter { $0.accountKey == accountKey }
    }
}
