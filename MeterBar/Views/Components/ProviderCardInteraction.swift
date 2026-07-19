import AppKit
import MeterBarShared
import SwiftUI

// Interaction affordances for the tappable provider cards. `ProviderStatusCard`
// is the single card shared by the popover, the dashboard Overview, and the
// Limits page. Previously those cards were clickable Buttons with no
// hover/pressed styling — the only cue was an accessibilityHint sighted users
// never see. These pieces make "clickable" visible and add a SwiftUI context
// menu mirroring the hidden status-item NSMenu.

// MARK: - Keyboard shortcuts

/// Central definition of the app's SwiftUI keyboard shortcuts so the popover and
/// dashboard bind the same key (and a test can assert it). ⌘R triggers a
/// refresh from whichever surface is key.
enum MeterBarShortcut {
    static let refreshKey: KeyEquivalent = "r"
    static let refreshModifiers: EventModifiers = .command
}

extension View {
    /// Binds ⌘R to a control, matching the native "Refresh" convention.
    func meterBarRefreshShortcut() -> some View {
        keyboardShortcut(MeterBarShortcut.refreshKey, modifiers: MeterBarShortcut.refreshModifiers)
    }
}

/// Quick curve for the hover/press affordance. Kept local so it doesn't depend
/// on the optional `MeterBarTheme.Motion` token (not present on every branch);
/// matches that token's `.snappy(0.18)` disclosure feel.
private let providerCardHoverAnimation: Animation = .snappy(duration: 0.18)

// MARK: - Hover / pressed button style

/// Button style for the tappable provider cards. Adds a subtle fill + accent
/// stroke on hover and a slight scale on press so the card visibly reads as
/// interactive. Non-tappable cards must NOT use this — keeping the distinction
/// meaningful is the whole point. Uses a quick snappy curve and honors Reduce
/// Motion.
struct ProviderCardButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        ProviderCardButtonSurface(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct ProviderCardButtonSurface: View {
        let configuration: Configuration
        let cornerRadius: CGFloat

        @State private var isHovering = false
        @Environment(\.accessibilityReduceMotion)
        private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let active = isHovering || configuration.isPressed

            configuration.label
                .overlay {
                    // Hover/press feedback is a quiet neutral wash + a slightly
                    // deeper hairline in the card's own tone — no scale (that
                    // resampled the text and read as blur), no drop shadow, no
                    // accent color. The card stays put; it just responds.
                    shape
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.06 : (isHovering ? 0.03 : 0)))
                        .allowsHitTesting(false)
                }
                .overlay {
                    shape
                        .strokeBorder(Color.primary.opacity(active ? 0.12 : 0), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .animation(reduceMotion ? nil : providerCardHoverAnimation, value: isHovering)
                .animation(reduceMotion ? nil : providerCardHoverAnimation, value: configuration.isPressed)
                .onHover { isHovering = $0 }
        }
    }
}

// MARK: - Disclosure chevron

/// Trailing `chevron.right` shown on cards that open a detail panel, so the
/// affordance is visible rather than implied. Hidden from accessibility because
/// the parent button already carries a "opens details" hint/label.
struct CardDisclosureChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

// MARK: - Context-menu command model

/// One action offered by a provider card's context menu. Pure data plus a
/// closure so the menu renders in SwiftUI and is asserted in tests without a
/// view host. Mirrors/extends the hidden status-item NSMenu.
struct ProviderCardCommand: Identifiable {
    enum Kind: String, CaseIterable {
        case refresh
        case openStatusPage
        case hide
        case openInDashboard
    }

    let id: Kind
    let title: String
    let systemImage: String
    let isDestructive: Bool
    let action: () -> Void
}

enum ProviderCardCommands {
    /// Builds the ordered command list. Side effects are injected so tests can
    /// fire each command against spies; `standard(...)` wires the real stores.
    static func make(
        snapshot: ProviderSnapshot,
        refresh: @escaping (ServiceType) -> Void,
        openStatusPage: @escaping (ServiceType) -> Void,
        hide: @escaping (ServiceType) -> Void,
        openInDashboard: @escaping () -> Void
    ) -> [ProviderCardCommand] {
        let service = snapshot.service
        return [
            ProviderCardCommand(
                id: .refresh,
                title: "Refresh this provider",
                systemImage: "arrow.clockwise",
                isDestructive: false,
                action: { refresh(service) }
            ),
            ProviderCardCommand(
                id: .openStatusPage,
                title: "Open status page",
                systemImage: "arrow.up.right.square",
                isDestructive: false,
                action: { openStatusPage(service) }
            ),
            ProviderCardCommand(
                id: .openInDashboard,
                title: "Open in Dashboard",
                systemImage: "rectangle.split.2x1",
                isDestructive: false,
                action: openInDashboard
            ),
            ProviderCardCommand(
                id: .hide,
                title: "Hide provider",
                systemImage: "eye.slash",
                isDestructive: true,
                action: { hide(service) }
            ),
        ]
    }

    /// Production wiring: refresh through `UsageDataManager`, open the public
    /// status page, hide via `ProviderVisibilityStore`, and open/focus the
    /// dashboard on this provider. `openInDashboard` defaults to bringing up the
    /// dashboard window focused on the card's provider — correct for both the
    /// popover (opens the window) and the dashboard (brings it forward + focuses).
    static func standard(
        snapshot: ProviderSnapshot,
        openInDashboard: (() -> Void)? = nil
    ) -> [ProviderCardCommand] {
        make(
            snapshot: snapshot,
            refresh: { service in
                Task { await UsageDataManager.shared.refresh(service: service) }
            },
            openStatusPage: { service in
                guard let url = service.statusPageURL else { return }
                NSWorkspace.shared.open(url)
            },
            hide: { service in
                ProviderVisibilityStore.shared.set(service, isEnabled: false)
                Task { await UsageDataManager.shared.refresh(service: service) }
            },
            openInDashboard: openInDashboard ?? {
                UsageDashboardWindowController.shared.show(
                    section: .limits,
                    focusedProviderID: snapshot.id
                )
            }
        )
    }
}

extension View {
    /// Attaches the provider-card context menu built from `commands`.
    func providerCardContextMenu(_ commands: [ProviderCardCommand]) -> some View {
        contextMenu {
            ForEach(commands) { command in
                Button(role: command.isDestructive ? .destructive : nil, action: command.action) {
                    Label(command.title, systemImage: command.systemImage)
                }
            }
        }
    }
}
