import AppKit
import SwiftUI

final class KeyableMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MeterBarMenuPanelController {
    private let statusButtonProvider: () -> NSStatusBarButton?
    private let onDismiss: () -> Void

    private var panel: NSPanel?
    private var contentSize = NSSize(width: 390, height: 420)
    private var globalMouseMonitor: Any?
    private var localEventMonitor: Any?

    var isShown: Bool {
        panel?.isVisible == true
    }

    init(
        statusButtonProvider: @escaping () -> NSStatusBarButton?,
        onDismiss: @escaping () -> Void
    ) {
        self.statusButtonProvider = statusButtonProvider
        self.onDismiss = onDismiss
    }

    func show() {
        guard let button = statusButtonProvider() else { return }
        let panel = ensurePanel()
        position(panel, anchoredTo: button, size: contentSize)
        panel.makeKeyAndOrderFront(nil)
        startEventMonitoring()
    }

    func dismiss() {
        stopEventMonitoring()
        panel?.orderOut(nil)
        onDismiss()
    }

    func resize(to size: NSSize) {
        contentSize = size
        guard let panel, panel.isVisible, let button = statusButtonProvider() else { return }
        position(panel, anchoredTo: button, size: size)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = KeyableMenuPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
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

    private func position(_ panel: NSPanel, anchoredTo button: NSStatusBarButton, size: NSSize) {
        guard let buttonWindow = button.window else { return }

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

        panel.setFrame(
            NSRect(x: x, y: y, width: size.width, height: size.height),
            display: true
        )
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
