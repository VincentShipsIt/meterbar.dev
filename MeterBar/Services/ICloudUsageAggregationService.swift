import Combine
import Foundation

/// App-facing coordinator. The opt-in guard is deliberately before every
/// repository call: disabled means zero CloudKit access, not merely zero writes.
final class ICloudUsageAggregationService: ObservableObject {
    static let shared = ICloudUsageAggregationService(
        settings: .shared,
        repository: CloudKitUsageRepository()
    )

    @Published private(set) var aggregate: ICloudUsageAggregationResult?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastSyncedAt: Date?

    let settings: ICloudUsageSettingsStore

    private let repository: any ICloudUsageRepository
    private let now: () -> Date

    init(
        settings: ICloudUsageSettingsStore,
        repository: any ICloudUsageRepository,
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.repository = repository
        self.now = now
    }

    func sync(
        localSummary: CostSummary?,
        quotaSnapshots: [ICloudQuotaSnapshot]
    ) async {
        guard settings.isEnabled else {
            aggregate = nil
            lastError = nil
            return
        }
        guard !isSyncing else { return }

        isSyncing = true
        defer { isSyncing = false }
        let syncDate = now()
        let device = ICloudUsageDevice(
            id: settings.deviceID,
            name: settings.deviceName,
            lastSeenAt: syncDate
        )
        let rollups = ICloudUsageAggregation.localRollups(
            deviceID: settings.deviceID,
            summary: localSummary,
            quotaSnapshots: quotaSnapshots,
            now: syncDate
        )

        do {
            let snapshot = try await repository.synchronize(device: device, rollups: rollups)
            aggregate = ICloudUsageAggregation.fold(
                devices: snapshot.devices,
                rollups: snapshot.rollups,
                now: syncDate
            )
            lastError = nil
            lastSyncedAt = syncDate
        } catch {
            // Availability-biased just like provider refresh: callers continue
            // to render CostTracker's local summary and never blank the page.
            aggregate = nil
            lastError = "iCloud usage sync is unavailable. Local totals are still shown."
        }
    }

    func removeDevice(_ device: ICloudUsageDevice) async {
        guard settings.isEnabled, device.id != settings.deviceID else { return }
        do {
            try await repository.removeDevice(id: device.id)
            if let aggregate {
                let remainingDevices = aggregate.devices.filter { $0.id != device.id }
                // CloudKit zone deletion is authoritative. Clear the projection
                // immediately; the next sync refills it from remaining zones.
                self.aggregate = ICloudUsageAggregation.fold(
                    devices: remainingDevices,
                    rollups: aggregate.rollups.filter { $0.deviceID != device.id },
                    now: now()
                )
            }
            lastError = nil
        } catch {
            lastError = "The Mac could not be removed from iCloud. Try again later."
        }
    }
}
