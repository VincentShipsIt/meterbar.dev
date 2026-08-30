import Combine
import Foundation

/// App-facing coordinator. The opt-in guard is deliberately before every
/// repository call: disabled means zero CloudKit access, not merely zero writes.
@MainActor
final class ICloudUsageAggregationService: ObservableObject {
    static let shared = ICloudUsageAggregationService(
        settings: .shared,
        repository: CloudKitUsageRepository(),
        quotaSnapshots: { await ICloudQuotaSnapshotSource.live() },
        prepareLocalSummary: { candidate in
            await CostTracker.shared.prepareSummaryForICloudPublication(candidate)
        }
    )

    @Published private(set) var aggregate: ICloudUsageAggregationResult?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastSyncedAt: Date?

    let settings: ICloudUsageSettingsStore

    private let repository: any ICloudUsageRepository
    private let now: () -> Date
    private let quotaSnapshots: () async -> [ICloudQuotaSnapshot]
    private let prepareLocalSummary: (CostSummary?) async -> ICloudUsageSummaryPreparationResult

    init(
        settings: ICloudUsageSettingsStore,
        repository: any ICloudUsageRepository,
        now: @escaping () -> Date = Date.init,
        quotaSnapshots: @escaping () async -> [ICloudQuotaSnapshot] = { [] },
        prepareLocalSummary: @escaping (CostSummary?) async -> ICloudUsageSummaryPreparationResult = { _ in .failed }
    ) {
        self.settings = settings
        self.repository = repository
        self.now = now
        self.quotaSnapshots = quotaSnapshots
        self.prepareLocalSummary = prepareLocalSummary
    }

    /// Production entry point. Quota collection lives here so no UI or
    /// lifecycle caller can accidentally replace a current CloudKit record
    /// with an empty quota payload.
    func sync(localSummary: CostSummary?) async {
        guard settings.isEnabled else {
            await sync(localSummary: localSummary, quotaSnapshots: [])
            return
        }
        let snapshots = await quotaSnapshots()
        await sync(localSummary: localSummary, quotaSnapshots: snapshots)
    }

    /// Prepared-payload seam for deterministic repository tests.
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
        let publishableSummary: CostSummary?
        if localSummary?.hasAuthoritativeICloudDailyCoverage != true {
            let preparation = await prepareLocalSummary(localSummary)
            guard settings.isEnabled else {
                aggregate = nil
                lastError = nil
                return
            }
            guard case let .completed(prepared) = preparation,
                  prepared.localScanCompletion != .incomplete,
                  prepared.hasAuthoritativeDailyCacheCreationTokens else {
                aggregate = nil
                lastError = "Local cost history needs a full scan before it can sync to iCloud."
                return
            }
            publishableSummary = prepared
        } else {
            publishableSummary = localSummary
        }
        let syncDate = now()
        let device = ICloudUsageDevice(
            id: settings.deviceID,
            name: settings.deviceName,
            lastSeenAt: syncDate
        )
        let rollups = ICloudUsageAggregation.localRollups(
            deviceID: settings.deviceID,
            summary: publishableSummary,
            quotaSnapshots: quotaSnapshots,
            now: syncDate
        )

        guard settings.isEnabled else {
            aggregate = nil
            lastError = nil
            return
        }
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
