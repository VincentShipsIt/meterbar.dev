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

    /// The quota each status item currently shows, by item id; feeds the sticky
    /// selection so concurrent Claude + Codex use doesn't flip the title.
    /// Per-item rather than a single key because account modes give each account
    /// its own slot, and one shared anchor would apply one item's history to all.
    private var shownKeys: [String: String] = [:]

    /// Monotonic stamp for status-item updates: activity probes run off the
    /// main actor, so a stale in-flight result must not overwrite a newer one.
    private var updateGeneration = 0

    /// Latest probed candidates, kept so the right-click switcher can list every
    /// pinnable window without re-running the probes.
    private(set) var latestCandidates: [StatusLimitCandidate] = []

    /// Account scope of the items currently in the menu bar. Held so a
    /// right-click can ask which account the clicked item speaks for without
    /// recomputing the plan (and risking a different answer than what is shown).
    private var accountItemPlan: MenuBarAccountItemPlan?

    /// Menu bar icons are rebuilt on every refresh; rasterizing the provider
    /// logos once keeps that off the hot path.
    private var imageCache: [String: NSImage] = [:]

    /// Exhausted-window countdowns change independently of provider refreshes.
    /// This timer only re-runs the pure presentation pass; it never repeats the
    /// directory activity probes or performs network work.
    private var countdownTimer: Timer?

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
        let plan = accountPlan(mode: preferences.presentationMode)
        accountItemPlan = plan
        let descriptors = MenuBarStatusItemPlanner.plan(
            mode: preferences.presentationMode,
            accountPlan: plan,
            candidates: candidates,
            previousKey: shownKeys[MenuBarStatusItemPlanner.mergedItemID],
            previousKeys: shownKeys,
            pinnedKey: preferences.pinnedCandidateKey,
            metric: preferences.labelMetric,
            size: preferences.labelSize,
            windowMode: preferences.windowMode,
            fontSize: preferences.fontSize,
            highContrast: preferences.highContrast,
            showsExhaustedResetCountdown: preferences.showsExhaustedResetCountdown
        )

        // Rebuilt rather than merged, so an item that just left the plan doesn't
        // keep anchoring a slot it no longer owns. Per-provider items report no
        // key and so contribute nothing.
        shownKeys = descriptors.reduce(into: [:]) { keys, descriptor in
            if let key = descriptor.selectionKey { keys[descriptor.id] = key }
        }

        applyDescriptors(descriptors)
        updateCountdownTimer(preferences: preferences)
    }

    /// Which accounts own an item right now, so the delegate can build the
    /// switcher submenu for the item the user right-clicked.
    @MainActor
    func accountEntry(for itemID: String) -> MenuBarAccountItemEntry? {
        accountItemPlan?.entries.first { $0.id == itemID }
    }

    /// The account the switcher item actually shows, which is not always the
    /// persisted preference: the planner falls back to the first enabled account
    /// when the stored key names a removed or untracked one. Checking the raw
    /// preference in the menu would tick an account the menu bar isn't showing.
    @MainActor
    func activeSwitcherAccountKey() -> String? {
        accountItemPlan?.entries.first { $0.showsAccountSwitcher }?.accountKey
            ?? MenuBarAccountSelectionStore.shared.mergedAccountKey
    }

    /// Every tracked Claude and Codex account, already sanitized for display.
    @MainActor
    func menuBarAccounts() -> [MenuBarAccountIdentity] {
        MenuBarAccountCatalog.identities(
            claudeAccounts: ClaudeCodeAccountStore.shared.accounts,
            codexAccounts: CodexAccountStore.shared.accounts,
            enabledServices: ProviderVisibilityStore.shared.enabledServices
        )
    }

    /// Reads the account stores on the main actor so the planners themselves
    /// stay pure and testable.
    @MainActor
    private func accountPlan(mode: MenuBarPresentationMode) -> MenuBarAccountItemPlan {
        let selection = MenuBarAccountSelectionStore.shared
        return MenuBarAccountItemPlanner.plan(
            mode: mode,
            selectedAccountKeys: selection.selectedAccountKeys,
            mergedAccountKey: selection.mergedAccountKey,
            accounts: menuBarAccounts()
        )
    }

    @MainActor
    func apply(_ descriptor: MenuBarStatusItemDescriptor, to button: NSStatusBarButton) {
        button.image = image(for: descriptor.service)
        button.imagePosition = descriptor.title.isEmpty ? .imageOnly : .imageLeft
        applyVisualStyle(descriptor.visualStyle, to: button)
        setTitle(button, to: descriptor.title, style: descriptor.visualStyle)
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
    private func setTitle(
        _ button: NSStatusBarButton,
        to newTitle: String,
        style: StatusItemVisualStyle
    ) {
        if button.title != newTitle,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            button.wantsLayer = true
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.22
            button.layer?.add(fade, forKey: "titleFade")
        }
        // Assigning `title` after clearing `attributedTitle` restores AppKit's
        // native menu-bar rendering when high contrast is turned back off.
        button.attributedTitle = NSAttributedString()
        button.title = newTitle
        guard style.highContrast else { return }
        button.attributedTitle = NSAttributedString(
            string: newTitle,
            attributes: [
                .font: button.font ?? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: Self.highContrastColor
            ]
        )
    }

    @MainActor
    private func applyVisualStyle(_ style: StatusItemVisualStyle, to button: NSStatusBarButton) {
        let explicitPointSize = style.fontSize.pointSize.map { CGFloat($0) }
        if style.highContrast {
            button.font = .systemFont(
                ofSize: explicitPointSize ?? NSFont.systemFontSize,
                weight: .bold
            )
        } else if let explicitPointSize {
            button.font = .systemFont(ofSize: explicitPointSize)
        } else {
            // `nil` restores NSStatusBarButton's native typography after an
            // opt-in font size or contrast mode is turned back off.
            button.font = nil
        }
        button.contentTintColor = style.highContrast ? Self.highContrastColor : nil
    }

    private static let highContrastColor = NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? .white : .black
    }

    @MainActor
    private func updateCountdownTimer(preferences: MenuBarDisplayPreferencesStore) {
        let now = Date()
        let needsTimer = preferences.showsExhaustedResetCountdown
            && latestCandidates.contains {
                $0.limit.isAtLimit && ($0.limit.resetTime ?? .distantPast) > now
            }
        guard needsTimer else {
            countdownTimer?.invalidate()
            countdownTimer = nil
            return
        }
        guard countdownTimer == nil else { return }

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apply(candidates: self.latestCandidates)
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
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
