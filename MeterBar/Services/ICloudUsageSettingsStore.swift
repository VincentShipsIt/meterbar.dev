import Combine
import Foundation

/// Opt-in and stable per-install identity for private iCloud aggregation.
/// Reading this store is local-only; CloudKit is not touched until `isEnabled`.
@MainActor
final class ICloudUsageSettingsStore: ObservableObject {
    static let shared = ICloudUsageSettingsStore()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var showsAllMacs: Bool
    @Published private(set) var deviceName: String

    let deviceID: UUID

    var recordZoneName: String { "MeterBarUsage-\(deviceID.uuidString)" }

    private let userDefaults: UserDefaults

    init(
        userDefaults: UserDefaults = .standard,
        defaultDeviceName: () -> String = {
            Host.current().localizedName ?? "This Mac"
        }
    ) {
        self.userDefaults = userDefaults
        if let rawID = userDefaults.string(forKey: StorageKeys.iCloudUsageDeviceID),
           let savedID = UUID(uuidString: rawID) {
            deviceID = savedID
        } else {
            let generated = UUID()
            deviceID = generated
            userDefaults.set(generated.uuidString, forKey: StorageKeys.iCloudUsageDeviceID)
        }

        let savedName = userDefaults.string(forKey: StorageKeys.iCloudUsageDeviceName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        deviceName = savedName.flatMap { $0.isEmpty ? nil : $0 } ?? defaultDeviceName()
        let enabled = userDefaults.bool(forKey: StorageKeys.iCloudUsageEnabled)
        isEnabled = enabled
        showsAllMacs = enabled && userDefaults.bool(forKey: StorageKeys.iCloudUsageShowsAllMacs)
        userDefaults.set(deviceName, forKey: StorageKeys.iCloudUsageDeviceName)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        userDefaults.set(enabled, forKey: StorageKeys.iCloudUsageEnabled)
        if !enabled {
            setShowsAllMacs(false)
        }
    }

    func setShowsAllMacs(_ enabled: Bool) {
        let normalized = isEnabled && enabled
        guard normalized != showsAllMacs else { return }
        showsAllMacs = normalized
        userDefaults.set(normalized, forKey: StorageKeys.iCloudUsageShowsAllMacs)
    }

    func setDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != deviceName else { return }
        deviceName = trimmed
        userDefaults.set(trimmed, forKey: StorageKeys.iCloudUsageDeviceName)
    }
}
