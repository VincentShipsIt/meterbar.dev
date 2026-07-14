import Foundation
import ServiceManagement

enum SessionWakeAgentRegistrationStatus: Equatable, Sendable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case unknown
}

/// ServiceManagement seam for the managed launch agent. The concrete service
/// points at the plist embedded in MeterBar.app; controller tests use a fake so
/// they never mutate the user's login-item database.
protocol SessionWakeAgentControlling {
    var isAvailable: Bool { get }
    func currentStatus() -> SessionWakeAgentRegistrationStatus
    func register() throws
    func unregister() throws
}

struct SMAppServiceSessionWakeAgent: SessionWakeAgentControlling {
    static let plistName = "dev.meterbar.app.session-wake.plist"

    private var service: SMAppService {
        SMAppService.agent(plistName: Self.plistName)
    }

    var isAvailable: Bool {
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let executable = contents.appendingPathComponent("Helpers/meterbar")
        let plist = contents.appendingPathComponent("Library/LaunchAgents/\(Self.plistName)")
        return FileManager.default.isExecutableFile(atPath: executable.path)
            && FileManager.default.fileExists(atPath: plist.path)
    }

    func currentStatus() -> SessionWakeAgentRegistrationStatus {
        switch service.status {
        case .enabled: return .enabled
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
