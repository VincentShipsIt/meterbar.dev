import Combine
import Foundation
import IOKit
import os

/// Not sourced from `StorageKeys` (`MeterBar/Models/StorageKeys.swift`)
/// because issue #548's fix is scoped to only this file and
/// `CloudKitUsageRepository.swift`. Follow-up: fold this into `StorageKeys`
/// alongside the other `iCloudUsage*` keys.
private enum LocalStorageKeys {
    static let hardwareAnchor = "ICloudUsageHardwareAnchorID"
}

/// Opt-in and stable per-install identity for private iCloud aggregation.
/// Reading this store is local-only; CloudKit is not touched until `isEnabled`.
@MainActor
final class ICloudUsageSettingsStore: ObservableObject {
    static let shared = ICloudUsageSettingsStore()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var showsAllMacs: Bool
    @Published private(set) var deviceName: String

    /// Set when the saved device ID was discarded and regenerated because the
    /// hardware anchor it was saved alongside no longer matches this Mac's own
    /// hardware — see `init`. Surfaced for diagnostics/future UI; does not by
    /// itself change any CloudKit behavior.
    @Published private(set) var identityCollisionDetected: Bool

    let deviceID: UUID

    var recordZoneName: String { "MeterBarUsage-\(deviceID.uuidString)" }

    private let userDefaults: UserDefaults

    /// - Parameters:
    ///   - hardwareAnchor: this Mac's stable hardware identifier, used to
    ///     detect a `UserDefaults` domain cloned onto different hardware.
    ///     Injectable for tests; production defaults to the IOKit platform
    ///     UUID (`currentHardwareAnchor()`).
    init(
        userDefaults: UserDefaults = .standard,
        defaultDeviceName: () -> String = {
            Host.current().localizedName ?? "This Mac"
        },
        hardwareAnchor: () -> String? = { ICloudUsageSettingsStore.currentHardwareAnchor() }
    ) {
        self.userDefaults = userDefaults
        let anchor = hardwareAnchor()
        let savedAnchor = userDefaults.string(forKey: LocalStorageKeys.hardwareAnchor)

        if let rawID = userDefaults.string(forKey: StorageKeys.iCloudUsageDeviceID),
           let savedID = UUID(uuidString: rawID) {
            if let anchor, let savedAnchor, anchor != savedAnchor {
                // The saved device ID was written alongside a different Mac's
                // hardware anchor. `UserDefaults` domains are copied whole by
                // Migration Assistant and Time Machine restores, so reusing
                // `savedID` here would make this Mac write into the same
                // CloudKit zone (`MeterBarUsage-<savedID>`) as the machine it
                // was cloned from — CloudKit keeps one record per name, so the
                // two Macs' daily rollups would overwrite each other instead
                // of summing. Mint a fresh identity instead.
                //
                // Tradeoff: this only catches clones made *after* this fix
                // shipped, because it depends on an anchor that was saved on
                // the source Mac. A collision that already exists from an
                // earlier clone has no local signal to detect it by — the two
                // Macs' `UserDefaults` domains are, by construction,
                // indistinguishable. Anchoring `deviceID` itself to hardware
                // instead of a random UUID would also close that gap, but
                // would change the zone-naming contract for every existing
                // install and was judged more invasive than this
                // detect-and-remint approach for what is otherwise a rare
                // event.
                let generated = UUID()
                deviceID = generated
                identityCollisionDetected = true
                userDefaults.set(generated.uuidString, forKey: StorageKeys.iCloudUsageDeviceID)
                AppLog.storage.error(
                    "iCloud usage identity collision detected (hardware anchor mismatch); minted a new device ID."
                )
            } else {
                deviceID = savedID
                identityCollisionDetected = false
            }
        } else {
            let generated = UUID()
            deviceID = generated
            identityCollisionDetected = false
            userDefaults.set(generated.uuidString, forKey: StorageKeys.iCloudUsageDeviceID)
        }
        // Only overwrite the saved anchor when we actually read one: a nil
        // `anchor` means IOKit couldn't answer this launch, and clearing a
        // previously-known-good anchor would blind every future launch to a
        // collision it could otherwise have detected.
        if let anchor {
            userDefaults.set(anchor, forKey: LocalStorageKeys.hardwareAnchor)
        }

        let savedName = userDefaults.string(forKey: StorageKeys.iCloudUsageDeviceName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        deviceName = savedName.flatMap { $0.isEmpty ? nil : $0 } ?? defaultDeviceName()
        let enabled = userDefaults.bool(forKey: StorageKeys.iCloudUsageEnabled)
        isEnabled = enabled
        showsAllMacs = enabled && userDefaults.bool(forKey: StorageKeys.iCloudUsageShowsAllMacs)
        userDefaults.set(deviceName, forKey: StorageKeys.iCloudUsageDeviceName)
    }

    /// This Mac's stable hardware identifier (`IOPlatformUUID`), read fresh
    /// from IOKit every launch so it can never be carried over by a cloned
    /// `UserDefaults` domain the way a persisted value could.
    nonisolated static func currentHardwareAnchor() -> String? {
        let matching = IOServiceMatching("IOPlatformExpertDevice")
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }
        guard let property = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return nil
        }
        return property.takeRetainedValue() as? String
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
