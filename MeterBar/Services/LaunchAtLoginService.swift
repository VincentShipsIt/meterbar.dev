import Foundation
import ServiceManagement

/// The login-item states MeterBar cares about, mapped from `SMAppService.Status`
/// so the store and its tests never depend on ServiceManagement directly.
enum LaunchAtLoginStatus: Equatable, Sendable {
    /// Registered and will launch at login.
    case enabled
    /// Not registered.
    case notRegistered
    /// Registered but the user must approve it in System Settings › Login Items.
    case requiresApproval
    /// The login item could not be found (e.g. running from an unexpected path).
    case notFound
    case unknown
}

/// The seam the `LaunchAtLoginStore` toggles against. The concrete
/// implementation wraps `SMAppService.mainApp`; tests substitute a fake so the
/// toggle logic is exercised without touching the real login-item database.
protocol LaunchAtLoginControlling {
    func currentStatus() -> LaunchAtLoginStatus
    func register() throws
    func unregister() throws
}

/// Thin `SMAppService.mainApp` wrapper. macOS 13+ (deployment target is 26), so
/// no availability guard is needed.
struct SMAppServiceLaunchAtLogin: LaunchAtLoginControlling {
    func currentStatus() -> LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
