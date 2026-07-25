import AppKit
import MeterBarShared
import QuartzCore

/// Owns everything that decides what the menu bar shows, extracted from
/// `MeterBarApp.swift` (C1 split).
///
/// The moving parts are unchanged: cheap main-actor inputs are gathered first,
/// the directory-scanning probes run off the main actor, and a generation
/// counter lets a newer update supersede an in-flight probe. What is new is the
/// boundary — the presenter decides, `MenuBarStatusItemPlanner` does the pure
/// per-item formatting, and creating or removing the items themselves is handed
/// back to the delegate, which is the only place that may touch `NSStatusBar`.
final class StatusItemPresenter {
    /// Realizes a plan: the delegate adds, removes, and reuses the status items
    /// and calls `apply(_:to:)` back for each surviving button.
    private let applyDescriptors: ([MenuBarStatusItemDescriptor]) -> Void

    /// The account whose quota the menu bar title currently shows; feeds the
    /// sticky selection so concurrent Claude + Codex use doesn't flip the title.
    private var shownKey: String?

    /// Monotonic stamp for status-item updates: activity probes run off the
    /// main actor, so a stale in-flight result must not overwrite a newer one.
    private var updateGeneration = 0

    /// Latest probed candidates, kept so the right-click switcher can list every
    /// pinnable window without re-running the probes.
    private(set) var latestCandidates: [StatusLimitCandidate] = []

    /// Menu bar icons are rebuilt on every refresh; rasterizing the provider
    /// logos once keeps that off the hot path.
    private var imageCache: [String: NSImage] = [:]

    init(applyDescriptors: @escaping ([MenuBarStatusItemDescriptor]) -> Void) {
        self.applyDescriptors = applyDescriptors
    }

    @MainActor
    func update(metrics: [ServiceType: UsageMetrics]) {
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
        latestCandidates = candidates

        let preferences = MenuBarDisplayPreferencesStore.shared
        let descriptors = MenuBarStatusItemPlanner.plan(
            mode: preferences.presentationMode,
            candidates: candidates,
            previousKey: shownKey,
            pinnedKey: preferences.pinnedCandidateKey,
            metric: preferences.labelMetric,
            size: preferences.labelSize
        )

        // Only the merged item feeds sticky selection; per-provider items are
        // each nailed to one account and report no key at all.
        shownKey = descriptors
            .first { $0.id == MenuBarStatusItemPlanner.mergedItemID }?
            .selectionKey

        applyDescriptors(descriptors)
    }

    @MainActor
    func apply(_ descriptor: MenuBarStatusItemDescriptor, to button: NSStatusBarButton) {
        button.image = image(for: descriptor.service)
        button.imagePosition = descriptor.title.isEmpty ? .imageOnly : .imageLeft
        setTitle(button, to: descriptor.title)
        button.toolTip = descriptor.tooltip
        button.setAccessibilityLabel(descriptor.accessibilityLabel)
        applyParseHealthAppearance(to: button)
    }

    /// Provider glyph for the item, so a bare `52%` says *whose* 52% it is.
    /// Providers without a bundled logo keep MeterBar's own bars mark.
    @MainActor
    func image(for service: ServiceType?) -> NSImage {
        guard let resourceName = service.flatMap({ ProviderLogoKind.forService($0).resourceName }) else {
            return fallbackImage()
        }

        if let cached = imageCache[resourceName] { return cached }

        // The logo cache vends shared instances, so resize a copy — mutating
        // the original would shrink every popover icon too.
        guard let logo = ProviderLogoImageCache.image(named: resourceName)?.copy() as? NSImage else {
            return fallbackImage()
        }
        logo.size = NSSize(width: 16, height: 16)
        logo.isTemplate = true
        imageCache[resourceName] = logo
        return logo
    }

    @MainActor
    private func fallbackImage() -> NSImage {
        if let cached = imageCache[Self.fallbackImageKey] { return cached }

        let image = MenuBarIconRenderer.meterIcon()
        image.isTemplate = true
        imageCache[Self.fallbackImageKey] = image
        return image
    }

    /// Cache slot for the generic mark. Not a resource name, so it can't
    /// collide with a provider logo.
    private static let fallbackImageKey = "meterbar.fallback"

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

    static func attentionToolTip(base: String?) -> String {
        "\(base ?? fallbackLabel) · Provider data needs attention"
    }
}
