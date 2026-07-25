import AppKit
import MeterBarShared
import QuartzCore

/// Owns everything that decides what the menu-bar button shows, extracted from
/// `MeterBarApp.swift` (C1 split).
///
/// The moving parts are unchanged: cheap main-actor inputs are gathered first,
/// the directory-scanning probes run off the main actor, and a generation
/// counter lets a newer update supersede an in-flight probe. What is new is that
/// the button is reached through an injected provider instead of a stored
/// `NSStatusItem`, and the string formatting is split into pure statics so the
/// label/tooltip/accessibility branches are testable without a status bar.
final class StatusItemPresenter {
    private let statusButtonProvider: () -> NSStatusBarButton?
    private var shownKey: String?
    private var updateGeneration = 0

    init(statusButtonProvider: @escaping () -> NSStatusBarButton?) {
        self.statusButtonProvider = statusButtonProvider
    }

    @MainActor
    func update(metrics: [ServiceType: UsageMetrics]) {
        guard statusButtonProvider() != nil else { return }

        // Gather the cheap main-actor inputs now; run the activity probes
        // (directory scans) off the main actor; apply on return. A generation
        // counter lets a newer update supersede an in-flight probe.
        let requests = StatusLimitProbeRequestBuilder.requests(metrics: metrics)
        updateGeneration += 1
        let generation = updateGeneration

        Task { [weak self] in
            let candidates = await Task.detached(priority: .userInitiated) {
                StatusLimitProbeRequestBuilder.candidates(from: requests)
            }.value
            guard let self, generation == self.updateGeneration else { return }
            self.apply(candidates: candidates)
        }
    }

    @MainActor
    func apply(candidates: [StatusLimitCandidate]) {
        guard let button = statusButtonProvider() else { return }
        let preferences = MenuBarDisplayPreferencesStore.shared

        guard let selection = StatusItemLimitSelector.select(
            candidates: candidates,
            previousKey: shownKey,
            pinnedKey: preferences.pinnedCandidateKey
        ) else {
            shownKey = nil
            setTitle(button, to: "")
            button.imagePosition = .imageOnly
            button.toolTip = Self.fallbackLabel
            button.setAccessibilityLabel(Self.fallbackLabel)
            applyParseHealthAppearance(to: button)
            return
        }

        shownKey = selection.key
        let selectionName = Self.selectionName(
            displayName: selection.displayName,
            windowName: selection.windowName,
            isPinned: preferences.pinnedCandidateKey == selection.pinKey
        )
        let title = StatusItemLabelFormatter.title(
            for: selection.limit,
            metric: preferences.labelMetric,
            size: preferences.labelSize
        )
        let spokenValue = StatusItemLabelFormatter.spokenValue(
            for: selection.limit,
            metric: preferences.labelMetric
        )

        button.imagePosition = title == nil ? .imageOnly : .imageLeft
        setTitle(button, to: Self.buttonTitle(for: title))
        button.toolTip = Self.toolTip(spokenValue: spokenValue, selectionName: selectionName)
        button.setAccessibilityLabel(
            Self.accessibilityLabel(spokenValue: spokenValue, selectionName: selectionName)
        )
        applyParseHealthAppearance(to: button)
    }

    /// Sets the status-button title, crossfading the change so the menu-bar
    /// `NN%` doesn't snap on refresh. SwiftUI's `.contentTransition(.numericText())`
    /// can't reach this AppKit `NSStatusBarButton`, so we fade its layer instead.
    /// No-op fade when the title is unchanged or Reduce Motion is on.
    @MainActor
    private func setTitle(_ button: NSStatusBarButton, to newTitle: String) {
        if button.title != newTitle,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            button.wantsLayer = true
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.22
            button.layer?.add(fade, forKey: "titleFade")
        }
        button.title = newTitle
    }

    @MainActor
    private func applyParseHealthAppearance(to button: NSStatusBarButton) {
        let now = Date()
        let hasAttention = ProviderVisibilityStore.shared.enabledServices.contains { service in
            ProviderParseHealthStore.shared.records[service]?.needsAttention(now: now) == true
        }
        let targetAlpha: CGFloat = hasAttention ? 0.55 : 1
        // This runs on every status refresh; only animate when the value actually
        // changes so a steady state doesn't restart the fade each tick.
        if button.alphaValue != targetAlpha {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                button.alphaValue = targetAlpha
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = MeterBarTheme.Motion.statusItemAlpha
                    button.animator().alphaValue = targetAlpha
                }
            }
        }
        if hasAttention {
            button.toolTip = Self.attentionToolTip(base: button.toolTip)
        }
    }
}

// MARK: - Pure formatting

extension StatusItemPresenter {
    static let fallbackLabel = "MeterBar"

    /// A pinned candidate names its window too, because the user chose that
    /// specific quota rather than letting activity pick one.
    static func selectionName(displayName: String, windowName: String, isPinned: Bool) -> String {
        isPinned ? "\(displayName) · \(windowName)" : displayName
    }

    /// Leading space separates the label from the meter icon; no value means
    /// icon-only, so the title collapses to empty rather than a stray space.
    static func buttonTitle(for title: String?) -> String {
        title.map { " \($0)" } ?? ""
    }

    static func toolTip(spokenValue: String?, selectionName: String) -> String {
        guard let spokenValue else { return "\(fallbackLabel): \(selectionName)" }
        return "\(fallbackLabel): \(spokenValue) on \(selectionName)"
    }

    static func accessibilityLabel(spokenValue: String?, selectionName: String) -> String {
        guard let spokenValue else { return "\(fallbackLabel) \(selectionName)" }
        return "\(fallbackLabel) \(spokenValue) on \(selectionName)"
    }

    static func attentionToolTip(base: String?) -> String {
        "\(base ?? fallbackLabel) · Provider data needs attention"
    }
}
