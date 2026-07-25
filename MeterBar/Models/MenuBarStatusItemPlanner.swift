import Foundation
import MeterBarShared

// MARK: - MenuBarStatusItemPlanEntry

/// One status item the menu bar should own.
nonisolated struct MenuBarStatusItemPlanEntry: Equatable, Identifiable, Sendable {
    // MARK: Internal

    /// Identity of the live `NSStatusItem`. Stable across retitles so an item
    /// keeps its slot in the menu bar.
    static let aggregateID = "aggregate"
    static let mergedID = "merged"

    /// The legacy item: no account scope, competes across every candidate.
    static let aggregate = MenuBarStatusItemPlanEntry(
        id: aggregateID,
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

// MARK: - MenuBarStatusItemPlan

nonisolated struct MenuBarStatusItemPlan: Equatable, Sendable {
    let mode: MenuBarAccountDisplayMode
    let entries: [MenuBarStatusItemPlanEntry]

    var itemIDs: [String] { entries.map(\.id) }
}

// MARK: - MenuBarStatusItemPlanner

/// Turns a display mode plus a persisted account selection into the concrete set
/// of status items the app should own.
nonisolated enum MenuBarStatusItemPlanner {
    /// Menu-bar width is finite and shared with every other app's items, and
    /// macOS silently hides items that no longer fit. Four is deliberately
    /// conservative: it covers the common "work + personal, Claude + Codex"
    /// setup while still fitting a laptop-width menu bar.
    static let maximumConcurrentItems = 4

    static func plan(
        mode: MenuBarAccountDisplayMode,
        selectedAccountKeys: [String],
        mergedAccountKey: String?,
        accounts: [MenuBarAccountIdentity]
    ) -> MenuBarStatusItemPlan {
        switch mode {
        case .single:
            MenuBarStatusItemPlan(mode: .single, entries: [.aggregate])
        case .perAccount:
            perAccountPlan(selectedAccountKeys: selectedAccountKeys, accounts: accounts)
        case .merged:
            mergedPlan(mergedAccountKey: mergedAccountKey, accounts: accounts)
        }
    }

    // MARK: Private

    private static func perAccountPlan(
        selectedAccountKeys: [String],
        accounts: [MenuBarAccountIdentity]
    ) -> MenuBarStatusItemPlan {
        let enabled = accounts.filter(\.isEnabled)
        let entries = selectedAccountKeys
            .compactMap { key in enabled.first { $0.key == key } }
            .prefix(maximumConcurrentItems)
            .map { identity in
                MenuBarStatusItemPlanEntry(
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
            return MenuBarStatusItemPlan(mode: .perAccount, entries: [.aggregate])
        }
        return MenuBarStatusItemPlan(mode: .perAccount, entries: entries)
    }

    private static func mergedPlan(
        mergedAccountKey: String?,
        accounts: [MenuBarAccountIdentity]
    ) -> MenuBarStatusItemPlan {
        let enabled = accounts.filter(\.isEnabled)
        let active = mergedAccountKey.flatMap { key in enabled.first { $0.key == key } } ?? enabled.first
        guard let active else {
            return MenuBarStatusItemPlan(mode: .merged, entries: [.aggregate])
        }
        return MenuBarStatusItemPlan(mode: .merged, entries: [
            MenuBarStatusItemPlanEntry(
                id: MenuBarStatusItemPlanEntry.mergedID,
                accountKey: active.key,
                displayName: active.displayName,
                badge: active.badge,
                showsAccountSwitcher: true
            )
        ])
    }
}

// MARK: - MenuBarStatusItemDiff

/// Minimal reconciliation between the live status items and a new plan.
///
/// Menu-bar slots are positional: a re-created `NSStatusItem` reappears at the
/// end of the bar. Adding and removing only the difference keeps every retained
/// item — and its position — undisturbed when one account is disabled.
nonisolated struct MenuBarStatusItemDiff: Equatable, Sendable {
    let added: [String]
    let removed: [String]
    /// Existing items that survive, in their current order.
    let retained: [String]

    static func between(existing: [String], desired: [String]) -> MenuBarStatusItemDiff {
        let existingIDs = Set(existing)
        let desiredIDs = Set(desired)
        return MenuBarStatusItemDiff(
            added: desired.filter { !existingIDs.contains($0) },
            removed: existing.filter { !desiredIDs.contains($0) },
            retained: existing.filter { desiredIDs.contains($0) }
        )
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

/// The merged item's in-menu account switcher.
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

// MARK: - MenuBarStatusItemCandidateFilter

/// Scopes the shared candidate set to the account one status item represents.
enum MenuBarStatusItemCandidateFilter {
    static func candidates(
        for entry: MenuBarStatusItemPlanEntry,
        in candidates: [StatusLimitCandidate]
    ) -> [StatusLimitCandidate] {
        guard let accountKey = entry.accountKey else { return candidates }
        return candidates.filter { $0.accountKey == accountKey }
    }
}
