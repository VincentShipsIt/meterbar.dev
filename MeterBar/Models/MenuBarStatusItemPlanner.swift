import Foundation
import MeterBarShared

/// One `NSStatusItem` the app should own, fully resolved.
///
/// The AppDelegate can't be reached by `swift test` (the SwiftPM target excludes
/// `App/`), so every decision about *what* the menu bar shows lives here and the
/// delegate is left with nothing but "create, update, remove" mechanics.
struct MenuBarStatusItemDescriptor: Equatable, Identifiable, Sendable {
    /// Stable identity across refreshes. Reusing it keeps the item's menu-bar
    /// position (and its autosaved user ordering) instead of respawning it at
    /// the far left on every update.
    let id: String
    /// Provider whose logo the item wears; nil for the placeholder item.
    let service: ServiceType?
    /// Legacy Auto key fed back to `StatusItemLimitSelector` as `previousKey`,
    /// so hysteresis survives. Only merged mode has a meaningful value.
    let selectionKey: String?
    /// Menu bar label. Empty renders icon-only, and a non-empty title carries
    /// the leading space that separates it from the icon.
    let title: String
    let tooltip: String
    let accessibilityLabel: String
}

/// Turns the current quota candidates into the menu bar's status item layout.
enum MenuBarStatusItemPlanner {
    /// Identity of the single item in merged mode, and of the placeholder that
    /// keeps MeterBar reachable when there is nothing to show.
    ///
    /// `nonisolated` because `MenuBarAccountItemEntry.aggregate` reuses it to
    /// keep the fallback item in the same menu-bar slot.
    nonisolated static let mergedItemID = "merged"

    /// - Parameter accountPlan: which accounts own an item, for the two
    ///   account-scoped modes. Nil means "not account-scoped", which is what the
    ///   provider-level modes always want.
    static func plan(
        mode: MenuBarPresentationMode,
        accountPlan: MenuBarAccountItemPlan? = nil,
        candidates: [StatusLimitCandidate],
        previousKey: String?,
        pinnedKey: String?,
        metric: StatusItemLabelMetric,
        size: StatusItemLabelSize,
        now: Date = Date()
    ) -> [MenuBarStatusItemDescriptor] {
        let context = SelectionContext(
            previousKey: previousKey,
            pinnedKey: pinnedKey,
            metric: metric,
            size: size,
            now: now
        )

        switch mode {
        case .merged:
            return [mergedDescriptor(candidates: candidates, context: context)]
        case .perProvider:
            let descriptors = perProviderDescriptors(candidates: candidates, metric: metric, size: size)
            // Never return an empty plan: with no status item left the popover,
            // settings, and Quit all become unreachable.
            return descriptors.isEmpty ? [placeholderDescriptor] : descriptors
        case .perAccount, .accountSwitcher:
            let descriptors = accountDescriptors(
                entries: (accountPlan ?? .aggregate(mode: mode)).entries,
                candidates: candidates,
                context: context
            )
            return descriptors.isEmpty ? [placeholderDescriptor] : descriptors
        }
    }

    /// Every window the user can pin from the menu bar itself, deduplicated by
    /// pin key and ordered like the rest of the app.
    static func switcherOptions(for candidates: [StatusLimitCandidate]) -> [StatusItemPinOption] {
        var seen: Set<String> = []
        return candidates
            .sorted { lhs, rhs in
                (lhs.service.sortOrder, lhs.displayName, lhs.windowName)
                    < (rhs.service.sortOrder, rhs.displayName, rhs.windowName)
            }
            .compactMap { candidate in
                guard seen.insert(candidate.pinKey).inserted else { return nil }
                return StatusItemPinOption(
                    id: candidate.pinKey,
                    title: "\(candidate.displayName) · \(candidate.windowName)"
                )
            }
    }

    private static var placeholderDescriptor: MenuBarStatusItemDescriptor {
        MenuBarStatusItemDescriptor(
            id: mergedItemID,
            service: nil,
            selectionKey: nil,
            title: "",
            tooltip: "MeterBar",
            accessibilityLabel: "MeterBar"
        )
    }

    /// Everything `StatusItemLimitSelector` needs apart from the candidates
    /// themselves. Grouped so the per-account path can hand the same selection
    /// rules to each scoped candidate set without threading four arguments.
    private struct SelectionContext {
        let previousKey: String?
        let pinnedKey: String?
        let metric: StatusItemLabelMetric
        let size: StatusItemLabelSize
        let now: Date
    }

    private static func mergedDescriptor(
        candidates: [StatusLimitCandidate],
        context: SelectionContext
    ) -> MenuBarStatusItemDescriptor {
        guard let selection = StatusItemLimitSelector.select(
            candidates: candidates,
            previousKey: context.previousKey,
            pinnedKey: context.pinnedKey,
            now: context.now
        ) else {
            return placeholderDescriptor
        }

        // Auto already implies "whichever window matters", so the window name is
        // noise there; a pin is a deliberate choice of one window and says so.
        let isPinned = context.pinnedKey == selection.pinKey
        return descriptor(
            id: mergedItemID,
            selectionKey: selection.key,
            candidate: selection,
            qualifiedName: isPinned,
            metric: context.metric,
            size: context.size
        )
    }

    private static func perProviderDescriptors(
        candidates: [StatusLimitCandidate],
        metric: StatusItemLabelMetric,
        size: StatusItemLabelSize
    ) -> [MenuBarStatusItemDescriptor] {
        candidates
            .filter(\.isAutoSelectable)
            .sorted { lhs, rhs in
                // Deterministic order, otherwise the items reshuffle whenever
                // the candidate list is rebuilt.
                (lhs.service.sortOrder, lhs.key) < (rhs.service.sortOrder, rhs.key)
            }
            .map { candidate in
                descriptor(
                    id: candidate.pinKey,
                    selectionKey: nil,
                    candidate: candidate,
                    qualifiedName: true,
                    metric: metric,
                    size: size
                )
            }
    }

    /// One item per account the plan named, each competing only within its own
    /// account's candidates.
    private static func accountDescriptors(
        entries: [MenuBarAccountItemEntry],
        candidates: [StatusLimitCandidate],
        context: SelectionContext
    ) -> [MenuBarStatusItemDescriptor] {
        entries.compactMap { entry in
            let scoped = MenuBarAccountCandidateFilter.candidates(for: entry, in: candidates)
            // The unscoped fallback entry *is* the legacy merged item, so it
            // keeps the merged behavior including the placeholder.
            guard entry.accountKey != nil else {
                return mergedDescriptor(candidates: scoped, context: context)
            }
            // A pin naming a window outside this account simply doesn't match,
            // so passing it through only honors pins that belong here.
            guard let selection = StatusItemLimitSelector.select(
                candidates: scoped,
                previousKey: context.previousKey,
                pinnedKey: context.pinnedKey,
                now: context.now
            ) else { return nil }
            return descriptor(
                // Only the switcher item feeds its selection back as the next
                // `previousKey`; per-account items each own a slot already.
                id: entry.id,
                selectionKey: entry.showsAccountSwitcher ? selection.key : nil,
                candidate: selection,
                qualifiedName: false,
                metric: context.metric,
                size: context.size,
                badge: entry.badge,
                accountName: entry.displayName
            )
        }
    }

    private static func descriptor(
        id: String,
        selectionKey: String?,
        candidate: StatusLimitCandidate,
        qualifiedName: Bool,
        metric: StatusItemLabelMetric,
        size: StatusItemLabelSize,
        badge: String = "",
        accountName: String = ""
    ) -> MenuBarStatusItemDescriptor {
        let windowName = qualifiedName
            ? "\(candidate.displayName) · \(candidate.windowName)"
            : candidate.displayName
        // Two items for the same provider wear the same logo, so the account
        // name is what tells them apart in the tooltip.
        let name = accountName.isEmpty ? windowName : "\(accountName) · \(windowName)"
        let value = StatusItemLabelFormatter.title(for: candidate.limit, metric: metric, size: size)
        let spokenValue = StatusItemLabelFormatter.spokenValue(for: candidate.limit, metric: metric)
        let suffix = spokenValue.map { "\($0) on \(name)" } ?? name
        // Icon-only still shows the badge: without it, per-account items are
        // indistinguishable from each other in the menu bar.
        let segments = [badge, value ?? ""].filter { !$0.isEmpty }

        return MenuBarStatusItemDescriptor(
            id: id,
            service: candidate.service,
            selectionKey: selectionKey,
            title: segments.isEmpty ? "" : " " + segments.joined(separator: " "),
            tooltip: "MeterBar: \(suffix)",
            accessibilityLabel: "MeterBar \(suffix)"
        )
    }
}
