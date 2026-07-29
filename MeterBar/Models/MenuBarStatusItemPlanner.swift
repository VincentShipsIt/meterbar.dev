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
    /// Auto key fed back to `StatusItemLimitSelector` as this item's
    /// `previousKey` on the next refresh, so the 5-point hysteresis survives.
    /// Nil for per-provider items, which are nailed to one window already.
    let selectionKey: String?
    /// Menu bar label. Empty renders icon-only, and a non-empty title carries
    /// the leading space that separates it from the icon.
    let title: String
    let tooltip: String
    let accessibilityLabel: String
    let visualStyle: StatusItemVisualStyle
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
    /// - Parameter previousKey: what the merged item showed last refresh.
    /// - Parameter previousKeys: what each *account* item showed last refresh,
    ///   by item id. Account items each own a slot, so they each need their own
    ///   history; sharing the merged key would hand every item the same anchor.
    static func plan(
        mode: MenuBarPresentationMode,
        accountPlan: MenuBarAccountItemPlan? = nil,
        candidates: [StatusLimitCandidate],
        previousKey: String?,
        previousKeys: [String: String] = [:],
        pinnedKey: String?,
        metric: StatusItemLabelMetric,
        size: StatusItemLabelSize,
        windowMode: StatusItemWindowMode = .selected,
        fontSize: StatusItemFontSize = .standard,
        highContrast: Bool = false,
        showsExhaustedResetCountdown: Bool = false,
        now: Date = Date()
    ) -> [MenuBarStatusItemDescriptor] {
        let context = SelectionContext(
            previousKey: previousKey,
            previousKeys: previousKeys,
            pinnedKey: pinnedKey,
            metric: metric,
            size: size,
            windowMode: windowMode,
            visualStyle: StatusItemVisualStyle(fontSize: fontSize, highContrast: highContrast),
            showsExhaustedResetCountdown: showsExhaustedResetCountdown,
            now: now
        )

        switch mode {
        case .merged:
            return [mergedDescriptor(candidates: candidates, context: context)]
        case .perProvider:
            let descriptors = perProviderDescriptors(candidates: candidates, context: context)
            // Never return an empty plan: with no status item left the popover,
            // settings, and Quit all become unreachable.
            return descriptors.isEmpty ? [placeholderDescriptor(context: context)] : descriptors
        case .perAccount, .accountSwitcher:
            let descriptors = accountDescriptors(
                entries: (accountPlan ?? .aggregate(mode: mode)).entries,
                candidates: candidates,
                context: context
            )
            return descriptors.isEmpty ? [placeholderDescriptor(context: context)] : descriptors
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

    private static func placeholderDescriptor(context: SelectionContext) -> MenuBarStatusItemDescriptor {
        let content: DescriptorContent
        switch (context.windowMode, context.metric) {
        case (_, .iconOnly):
            content = DescriptorContent(visible: nil, spoken: nil)
        case (.selected, _):
            // Preserve the existing cold-launch icon-only placeholder unless
            // the user opted into one of the new content modes.
            content = context.metric == .pace
                ? DescriptorContent(visible: "—", spoken: "Pace unavailable")
                : DescriptorContent(visible: nil, spoken: nil)
        case (.combined, _):
            content = DescriptorContent(
                visible: "S— · W—",
                spoken: "Session usage unavailable; Weekly usage unavailable"
            )
        }
        return MenuBarStatusItemDescriptor(
            id: mergedItemID,
            service: nil,
            selectionKey: nil,
            title: content.visible.map { " \($0)" } ?? "",
            tooltip: content.spoken.map { "MeterBar: \($0)" } ?? "MeterBar",
            accessibilityLabel: content.spoken.map { "MeterBar \($0)" } ?? "MeterBar",
            visualStyle: context.visualStyle
        )
    }

    /// Everything `StatusItemLimitSelector` needs apart from the candidates
    /// themselves. Grouped so the per-account path can hand the same selection
    /// rules to each scoped candidate set without threading four arguments.
    private struct SelectionContext {
        let previousKey: String?
        let previousKeys: [String: String]
        let pinnedKey: String?
        let metric: StatusItemLabelMetric
        let size: StatusItemLabelSize
        let windowMode: StatusItemWindowMode
        let visualStyle: StatusItemVisualStyle
        let showsExhaustedResetCountdown: Bool
        let now: Date

        /// What the item with this id showed last refresh. The merged slot
        /// falls back to the standalone `previousKey` so a mode change into an
        /// account mode inherits the history instead of starting cold.
        func previousKey(forItem id: String) -> String? {
            previousKeys[id] ?? (id == mergedItemID ? previousKey : nil)
        }
    }

    private static func mergedDescriptor(
        candidates: [StatusLimitCandidate],
        context: SelectionContext
    ) -> MenuBarStatusItemDescriptor {
        guard let selection = StatusItemLimitSelector.select(
            candidates: candidates,
            previousKey: context.previousKey(forItem: mergedItemID),
            pinnedKey: context.pinnedKey,
            now: context.now
        ) else {
            return placeholderDescriptor(context: context)
        }

        // Auto already implies "whichever window matters", so the window name is
        // noise there; a pin is a deliberate choice of one window and says so.
        let isPinned = context.pinnedKey == selection.pinKey
        return descriptor(
            id: mergedItemID,
            selectionKey: selection.key,
            candidate: selection,
            candidates: candidates,
            qualifiedName: isPinned,
            context: context
        )
    }

    private static func perProviderDescriptors(
        candidates: [StatusLimitCandidate],
        context: SelectionContext
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
                    candidates: candidates,
                    qualifiedName: true,
                    context: context
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
                previousKey: context.previousKey(forItem: entry.id),
                pinnedKey: context.pinnedKey,
                now: context.now
            ) else { return nil }
            // Same rule as the merged item: Auto already means "whichever
            // window matters", but a pin is a deliberate choice and says which.
            let isPinned = context.pinnedKey == selection.pinKey
            return descriptor(
                // Every account item feeds its own selection back, so each slot
                // keeps its own hysteresis across refreshes.
                id: entry.id,
                selectionKey: selection.key,
                candidate: selection,
                candidates: scoped,
                qualifiedName: isPinned,
                context: context,
                badge: entry.badge,
                accountName: entry.displayName
            )
        }
    }

    private static func descriptor(
        id: String,
        selectionKey: String?,
        candidate: StatusLimitCandidate,
        candidates: [StatusLimitCandidate],
        qualifiedName: Bool,
        context: SelectionContext,
        badge: String = "",
        accountName: String = ""
    ) -> MenuBarStatusItemDescriptor {
        let qualifiesSelectedWindow = qualifiedName && context.windowMode == .selected
        let windowName = qualifiesSelectedWindow
            ? "\(candidate.displayName) · \(candidate.windowName)"
            : candidate.displayName
        // Two items for the same provider wear the same logo, so the account
        // name is what tells them apart in the tooltip.
        let name = accountName.isEmpty ? windowName : "\(accountName) · \(windowName)"
        let content = descriptorContent(candidate: candidate, candidates: candidates, context: context)
        let suffix = content.spoken.map { "\($0) on \(name)" } ?? name
        // Icon-only still shows the badge: without it, per-account items are
        // indistinguishable from each other in the menu bar.
        let segments = [badge, content.visible ?? ""].filter { !$0.isEmpty }

        return MenuBarStatusItemDescriptor(
            id: id,
            service: candidate.service,
            selectionKey: selectionKey,
            title: segments.isEmpty ? "" : " " + segments.joined(separator: " "),
            tooltip: "MeterBar: \(suffix)",
            accessibilityLabel: "MeterBar \(suffix)",
            visualStyle: context.visualStyle
        )
    }

    private struct DescriptorContent {
        let visible: String?
        let spoken: String?
    }

    private static func descriptorContent(
        candidate: StatusLimitCandidate,
        candidates: [StatusLimitCandidate],
        context: SelectionContext
    ) -> DescriptorContent {
        switch context.windowMode {
        case .selected:
            let value = formattedValue(for: candidate, context: context)
            return DescriptorContent(
                visible: value.visible,
                spoken: selectedSpokenValue(value.spoken, windowName: candidate.windowName)
            )
        case .combined:
            return combinedContent(anchor: candidate, candidates: candidates, context: context)
        }
    }

    private static func combinedContent(
        anchor: StatusLimitCandidate,
        candidates: [StatusLimitCandidate],
        context: SelectionContext
    ) -> DescriptorContent {
        guard context.metric != .iconOnly else {
            return DescriptorContent(visible: nil, spoken: nil)
        }

        let scoped = candidates.filter {
            $0.service == anchor.service && $0.accountKey == anchor.accountKey
        }
        let session = scoped.first { $0.windowID == "session" }
        let weekly = scoped.first { $0.windowID == "weekly" }
        let sessionValue = session.map { formattedValue(for: $0, context: context) }
            ?? unavailableValue(metric: context.metric)
        let weeklyValue = weekly.map { formattedValue(for: $0, context: context) }
            ?? unavailableValue(metric: context.metric)

        let visible = [
            StatusItemLabelFormatter.combinedToken(prefix: "S", value: sessionValue, size: context.size),
            StatusItemLabelFormatter.combinedToken(prefix: "W", value: weeklyValue, size: context.size)
        ].joined(separator: " · ")
        let spoken = [
            qualifiedSpokenValue(sessionValue.spoken, windowName: "Session"),
            qualifiedSpokenValue(weeklyValue.spoken, windowName: "Weekly")
        ].joined(separator: "; ")

        return DescriptorContent(visible: visible, spoken: spoken)
    }

    private static func formattedValue(
        for candidate: StatusLimitCandidate,
        context: SelectionContext
    ) -> StatusItemFormattedValue {
        StatusItemLabelFormatter.formatted(
            limit: candidate.limit,
            metric: context.metric,
            size: context.size,
            state: dataState(for: candidate, now: context.now),
            showsExhaustedResetCountdown: context.showsExhaustedResetCountdown,
            now: context.now
        )
    }

    private static func unavailableValue(metric: StatusItemLabelMetric) -> StatusItemFormattedValue {
        StatusItemLabelFormatter.formatted(
            limit: nil,
            metric: metric,
            size: .compact,
            state: .unavailable,
            showsExhaustedResetCountdown: false,
            now: .distantPast
        )
    }

    private static func dataState(for candidate: StatusLimitCandidate, now: Date) -> StatusItemDataState {
        let age = now.timeIntervalSince(candidate.lastUpdated)
        return age <= ProviderParseHealthRecord.staleAfter ? .fresh : .stale
    }

    private static func selectedSpokenValue(_ spoken: String?, windowName: String) -> String? {
        guard let spoken else { return nil }
        if spoken == "data stale"
            || spoken.contains("unavailable")
            || spoken.hasPrefix("reset")
            || spoken.hasPrefix("resets") {
            return qualifiedSpokenValue(spoken, windowName: windowName)
        }
        return spoken
    }

    private static func qualifiedSpokenValue(_ spoken: String?, windowName: String) -> String {
        "\(windowName) \(spoken ?? "usage unavailable")"
    }
}
