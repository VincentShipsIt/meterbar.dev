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
    static let mergedItemID = "merged"

    static func plan(
        mode: MenuBarPresentationMode,
        candidates: [StatusLimitCandidate],
        previousKey: String?,
        pinnedKey: String?,
        metric: StatusItemLabelMetric,
        size: StatusItemLabelSize,
        now: Date = Date()
    ) -> [MenuBarStatusItemDescriptor] {
        switch mode {
        case .merged:
            let descriptor = mergedDescriptor(
                candidates: candidates,
                previousKey: previousKey,
                pinnedKey: pinnedKey,
                metric: metric,
                size: size,
                now: now
            )
            return [descriptor]
        case .perProvider:
            let descriptors = perProviderDescriptors(candidates: candidates, metric: metric, size: size)
            // Never return an empty plan: with no status item left the popover,
            // settings, and Quit all become unreachable.
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

    private static func mergedDescriptor(
        candidates: [StatusLimitCandidate],
        previousKey: String?,
        pinnedKey: String?,
        metric: StatusItemLabelMetric,
        size: StatusItemLabelSize,
        now: Date
    ) -> MenuBarStatusItemDescriptor {
        guard let selection = StatusItemLimitSelector.select(
            candidates: candidates,
            previousKey: previousKey,
            pinnedKey: pinnedKey,
            now: now
        ) else {
            return placeholderDescriptor
        }

        // Auto already implies "whichever window matters", so the window name is
        // noise there; a pin is a deliberate choice of one window and says so.
        let isPinned = pinnedKey == selection.pinKey
        return descriptor(
            id: mergedItemID,
            selectionKey: selection.key,
            candidate: selection,
            qualifiedName: isPinned,
            metric: metric,
            size: size
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

    private static func descriptor(
        id: String,
        selectionKey: String?,
        candidate: StatusLimitCandidate,
        qualifiedName: Bool,
        metric: StatusItemLabelMetric,
        size: StatusItemLabelSize
    ) -> MenuBarStatusItemDescriptor {
        let name = qualifiedName
            ? "\(candidate.displayName) · \(candidate.windowName)"
            : candidate.displayName
        let title = StatusItemLabelFormatter.title(for: candidate.limit, metric: metric, size: size)
        let spokenValue = StatusItemLabelFormatter.spokenValue(for: candidate.limit, metric: metric)
        let suffix = spokenValue.map { "\($0) on \(name)" } ?? name

        return MenuBarStatusItemDescriptor(
            id: id,
            service: candidate.service,
            selectionKey: selectionKey,
            title: title.map { " \($0)" } ?? "",
            tooltip: "MeterBar: \(suffix)",
            accessibilityLabel: "MeterBar \(suffix)"
        )
    }
}
