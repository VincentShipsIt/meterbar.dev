import Combine
import Foundation

/// Backs the Settings "Launch at Login" row.
///
/// Holds the current `SMAppService.mainApp` status and drives register /
/// unregister through the injected `LaunchAtLoginControlling` seam. The status
/// can change behind the app's back (a user can remove the login item in System
/// Settings), so `refreshStatus()` re-reads it whenever Settings appears, and
/// registration failures surface via `lastError` for inline display.
final class LaunchAtLoginStore: ObservableObject {
    static let shared = LaunchAtLoginStore()

    @Published private(set) var status: LaunchAtLoginStatus
    @Published private(set) var lastError: String?

    private let controller: LaunchAtLoginControlling

    init(controller: LaunchAtLoginControlling = SMAppServiceLaunchAtLogin()) {
        self.controller = controller
        status = controller.currentStatus()
    }

    /// Whether MeterBar is currently registered to launch at login.
    var isEnabled: Bool { status == .enabled }

    /// Row subtitle that adapts to the current status (including the
    /// approval-required case the user must resolve in System Settings).
    var detailText: String {
        switch status {
        case .enabled:
            return "MeterBar opens automatically when you log in."
        case .requiresApproval:
            return "Approve MeterBar in System Settings › General › Login Items to finish enabling this."
        case .notRegistered, .notFound, .unknown:
            return "Open MeterBar automatically when you log in."
        }
    }

    /// Re-reads the live login-item status. Call when Settings appears so an
    /// external change (toggled in System Settings) is reflected.
    func refreshStatus() {
        status = controller.currentStatus()
    }

    /// Registers or unregisters the login item, surfacing any failure inline and
    /// always re-reading the resulting status so the toggle reflects reality.
    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try controller.register()
            } else {
                try controller.unregister()
            }
        } catch {
            let action = enabled ? "enable" : "disable"
            lastError = "Couldn't \(action) Launch at Login: \(error.localizedDescription)"
        }
        status = controller.currentStatus()
    }
}
