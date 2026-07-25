import AppKit
import os

/// Owns the app's live `NSStatusItem`s and reconciles them against a plan.
///
/// Before #266 the app held exactly one item. Multiple items make identity and
/// ordering matter: a re-created `NSStatusItem` reappears at the end of the menu
/// bar, so `reconcile(to:)` only adds and removes the difference and leaves every
/// retained item — and its slot — untouched.
@MainActor
final class MenuBarStatusItemController: NSObject {
    // MARK: Lifecycle

    init(makeIcon: @escaping @MainActor () -> NSImage) {
        self.makeIcon = makeIcon
        super.init()
    }

    // MARK: Internal

    /// Plan-entry id of the item the user clicked, so callers can route the
    /// popover and the context menu to the right account.
    var onClick: ((String) -> Void)?

    /// Live item ids in menu-bar order.
    private(set) var orderedIDs: [String] = []

    /// The item a popover should anchor to: the last one clicked, falling back
    /// to the first live item so an unprompted `show()` still has an anchor.
    var primaryButton: NSStatusBarButton? {
        let id = lastInteractedID.flatMap { orderedIDs.contains($0) ? $0 : nil } ?? orderedIDs.first
        return id.flatMap(button(for:))
    }

    func button(for id: String) -> NSStatusBarButton? {
        items[id]?.button
    }

    @discardableResult
    func reconcile(to ids: [String]) -> MenuBarStatusItemDiff {
        let diff = MenuBarStatusItemDiff.between(existing: orderedIDs, desired: ids)
        for id in diff.removed {
            if let item = items.removeValue(forKey: id) {
                NSStatusBar.system.removeStatusItem(item)
            }
        }
        for id in diff.added {
            guard let item = makeStatusItem() else {
                AppLog.app.error("Failed to create status item button")
                continue
            }
            items[id] = item
        }
        orderedIDs = ids.filter { items[$0] != nil }
        if let lastInteractedID, !orderedIDs.contains(lastInteractedID) {
            self.lastInteractedID = nil
        }
        return diff
    }

    // MARK: Private

    private let makeIcon: @MainActor () -> NSImage
    private var items: [String: NSStatusItem] = [:]
    private var lastInteractedID: String?

    private func makeStatusItem() -> NSStatusItem? {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return nil
        }
        let image = makeIcon()
        image.isTemplate = true
        button.image = image
        button.action = #selector(handleClick(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "MeterBar"
        button.imagePosition = .imageLeft
        button.font = .systemFont(ofSize: 14, weight: .semibold)
        return item
    }

    @objc
    private func handleClick(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton,
              let id = orderedIDs.first(where: { items[$0]?.button === button }) else { return }
        lastInteractedID = id
        onClick?(id)
    }
}
