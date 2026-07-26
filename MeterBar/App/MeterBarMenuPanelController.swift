import AppKit
import SwiftUI

final class KeyableMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MeterBarMenuPanelController {
    private static let anchorRetryDelay: TimeInterval = 0.02
    private static let anchorRetryWindow: TimeInterval = 0.2

    private let statusButtonProvider: () -> NSStatusBarButton?
    private let onDismiss: () -> Void

    private var panel: NSPanel?
    private var contentSize = NSSize(width: 390, height: 420)
    private var globalMouseMonitor: Any?
    private var localEventMonitor: Any?

    /// Intent flag, flipped synchronously by `show()`/`dismiss()`. Drives
    /// `isShown` so the toggle logic stays correct while a fade animation is
    /// still in flight (the panel's `isVisible` lags the fade-out completion).
    private var isPresented = false

    /// Bumped on every `show()`/`dismiss()`. Deferred anchor retries and fade-out
    /// completions only act while the token still matches, so stale work cannot
    /// resurrect or hide a newer presentation.
    private var presentationToken = 0

    /// Whether show/hide/resize animate. Defaults to honoring the system Reduce
    /// Motion setting; tests set it to `false` for deterministic end-states.
    var motionEnabled = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var isShown: Bool {
        isPresented
    }

    /// Test seam: the live panel once `show()` has created it.
    var presentedPanel: NSPanel? {
        panel
    }

    init(
        statusButtonProvider: @escaping () -> NSStatusBarButton?,
        onDismiss: @escaping () -> Void
    ) {
        self.statusButtonProvider = statusButtonProvider
        self.onDismiss = onDismiss
    }

    func show() {
        guard statusButtonProvider() != nil else { return }
        presentationToken &+= 1
        isPresented = true
        presentWhenAnchored(
            token: presentationToken,
            deadline: .now() + Self.anchorRetryWindow
        )
    }

    private func presentWhenAnchored(token: Int, deadline: DispatchTime) {
        guard isPresented, presentationToken == token else { return }
        guard let button = statusButtonProvider(),
              let frame = targetFrame(anchoredTo: button, size: contentSize) else {
            guard DispatchTime.now() < deadline else {
                // Do not leave togglePopover believing an invisible panel is
                // open after the bounded anchor-resolution window expires.
                isPresented = false
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.anchorRetryDelay) { [weak self] in
                self?.presentWhenAnchored(
                    token: token,
                    deadline: deadline
                )
            }
            return
        }

        let panel = ensurePanel()
        // Position before ordering front. A status item can exist for a run-loop
        // turn before AppKit attaches its window; showing the panel before this
        // frame resolves exposes its construction origin at the screen's
        // bottom-left.
        applyFrame(frame, to: panel, animated: false)
        if motionEnabled {
            // Assigning the model value cancels any in-flight fade-out and
            // restarts the fade from fully transparent.
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = MeterBarTheme.Motion.panelFadeIn
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
        }

        startEventMonitoring()
    }

    func dismiss() {
        stopEventMonitoring()
        let wasPresented = isPresented
        isPresented = false
        presentationToken &+= 1
        guard let panel else {
            onDismiss()
            return
        }
        let token = presentationToken

        if motionEnabled, wasPresented {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = MeterBarTheme.Motion.panelFadeOut
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                // The completion handler fires on the main thread; hop back onto
                // the main actor to touch isolated state.
                MainActor.assumeIsolated {
                    // Skip if a newer show/dismiss superseded this fade-out.
                    guard let self, self.presentationToken == token else { return }
                    panel.orderOut(nil)
                    panel.alphaValue = 1
                }
            })
        } else {
            panel.orderOut(nil)
            panel.alphaValue = 1
        }

        onDismiss()
    }

    func resize(to size: NSSize) {
        contentSize = size
        guard isPresented,
              let panel,
              let button = statusButtonProvider(),
              let frame = targetFrame(anchoredTo: button, size: size) else { return }
        applyFrame(frame, to: panel, animated: motionEnabled)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = KeyableMenuPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // ARC owns this reused panel; without this, AppKit's release-on-close
        // would double-free it (crashes XCTest's leak checker, and is unsafe).
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let hostingController = NSHostingController(
            rootView: MenuBarView { [weak self] size in
                self?.resize(to: size)
            }
        )
        panel.contentViewController = hostingController
        panel.applyCompanionClipping()

        self.panel = panel
        return panel
    }

    private func targetFrame(
        anchoredTo button: NSStatusBarButton,
        size: NSSize
    ) -> NSRect? {
        guard let buttonWindow = button.window else { return nil }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRect = buttonWindow.convertToScreen(buttonRectInWindow)
        let screen = buttonWindow.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? buttonRect
        let padding: CGFloat = 8

        let x = min(
            max(buttonRect.midX - (size.width / 2), visibleFrame.minX + padding),
            visibleFrame.maxX - size.width - padding
        )
        let y = max(visibleFrame.minY + padding, buttonRect.minY - size.height - 6)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func applyFrame(_ frame: NSRect, to panel: NSPanel, animated: Bool) {
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = MeterBarTheme.Motion.panelResize
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func startEventMonitoring() {
        stopEventMonitoring()

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }

            if event.type == .keyDown, event.keyCode == 53 {
                dismiss()
                return nil
            }

            if eventIsInsideStatusButton(event) {
                return event
            }

            if event.window === panel || MeterBarMenuDetailPanel.shared.owns(window: event.window) {
                return event
            }

            dismiss()
            return event
        }
    }

    private func eventIsInsideStatusButton(_ event: NSEvent) -> Bool {
        guard
            let button = statusButtonProvider(),
            event.window === button.window
        else {
            return false
        }

        let location = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(location)
    }

    private func stopEventMonitoring() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }
}
