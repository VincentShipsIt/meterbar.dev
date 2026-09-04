import CloudKit
import Foundation
import MeterBarShared

/// Production transport for MeterBar's private CloudKit database. Each install
/// owns one custom zone, tying its stable UUID to the deletion boundary.
actor CloudKitUsageRepository: ICloudUsageRepository {
    static let containerIdentifier = "iCloud.dev.meterbar.app"
    static let zonePrefix = "MeterBarUsage-"

    /// Per-zone change token plus the records it is a delta against. Without this
    /// every 15-minute sync re-downloads every rollup in every device zone.
    ///
    /// Deliberately process-scoped: persisting the token would also require
    /// persisting the decoded records, and one full resync per launch is cheaper
    /// than that invalidation surface.
    private var zoneStates: [CKRecordZone.ID: ZoneState] = [:]

    struct ZoneState {
        var changeToken: CKServerChangeToken?
        var records: [CKRecord.ID: CKRecord] = [:]
    }

    init() {}

    func synchronize(
        device: ICloudUsageDevice,
        rollups: [ICloudDailyUsageRollup]
    ) async throws -> ICloudUsageRepositorySnapshot {
        let database = privateDatabase()
        let zone = CKRecordZone(zoneName: zoneName(for: device.id))
        _ = try await database.modifyRecordZones(saving: [zone], deleting: [])

        let deviceRecord = CKRecord(
            recordType: ICloudUsageRecordSchema.deviceRecordType,
            recordID: CKRecord.ID(recordName: "device", zoneID: zone.zoneID)
        )
        Self.apply(ICloudUsageRecordSchema.fields(for: device), to: deviceRecord)

        let rollupRecords = try rollups.map { rollup -> CKRecord in
            let record = CKRecord(
                recordType: ICloudUsageRecordSchema.rollupRecordType,
                recordID: CKRecord.ID(recordName: rollup.recordName, zoneID: zone.zoneID)
            )
            Self.apply(try ICloudUsageRecordSchema.fields(for: rollup), to: record)
            return record
        }
        let modificationResults = try await database.modifyRecords(
            saving: [deviceRecord] + rollupRecords,
            deleting: [],
            savePolicy: .changedKeys,
            atomically: true
        )
        _ = try CloudKitResultCollector.values(from: modificationResults.saveResults)
        _ = try CloudKitResultCollector.values(from: modificationResults.deleteResults)

        return try await fetchSnapshot()
    }

    func removeDevice(id: UUID) async throws {
        let database = privateDatabase()
        let zoneID = CKRecordZone.ID(zoneName: zoneName(for: id), ownerName: CKCurrentUserDefaultName)
        let zoneResults = try await database.modifyRecordZones(saving: [], deleting: [zoneID])
        // CloudKit reports per-zone failures inside the result map rather than by
        // throwing, so an ignored `deleteResults` would let the caller clear local
        // state for a zone that still exists.
        _ = try CloudKitResultCollector.values(from: zoneResults.deleteResults)
        zoneStates[zoneID] = nil
    }

    private func fetchSnapshot() async throws -> ICloudUsageRepositorySnapshot {
        let database = privateDatabase()
        let zones = try await database.allRecordZones()
            .filter { $0.zoneID.zoneName.hasPrefix(Self.zonePrefix) }
        let liveZoneIDs = Set(zones.map(\.zoneID))
        zoneStates = zoneStates.filter { liveZoneIDs.contains($0.key) }
        var devices: [ICloudUsageDevice] = []
        var rollups: [ICloudDailyUsageRollup] = []

        for zone in zones {
            let zoneRecords = try await records(in: zone.zoneID)
            for record in zoneRecords {
                if let device = Self.decodeDevice(record) {
                    devices.append(device)
                } else if let rollup = Self.decodeRollup(record) {
                    rollups.append(rollup)
                }
            }
        }
        return ICloudUsageRepositorySnapshot(devices: devices, rollups: rollups)
    }

    private func records(in zoneID: CKRecordZone.ID) async throws -> [CKRecord] {
        do {
            return try await fetchChanges(in: zoneID, resuming: zoneStates[zoneID] ?? ZoneState())
        } catch let error as CKError where error.code == .changeTokenExpired {
            // The server dropped history behind our token, so the cached records it
            // was a delta against are no longer trustworthy either. Full resync.
            zoneStates[zoneID] = nil
            return try await fetchChanges(in: zoneID, resuming: ZoneState())
        }
    }

    /// Applies one delta pass on top of the zone's cached records. State is only
    /// committed once every page unwraps, so a partial failure leaves the previous
    /// token in place rather than acknowledging changes that were never decoded.
    private func fetchChanges(
        in zoneID: CKRecordZone.ID,
        resuming state: ZoneState
    ) async throws -> [CKRecord] {
        let database = privateDatabase()
        var state = state
        var moreComing = true
        while moreComing {
            let page = try await database.recordZoneChanges(
                inZoneWith: zoneID,
                since: state.changeToken
            )
            state = Self.merging(
                state,
                changed: try CloudKitResultCollector.values(from: page.modificationResultsByID)
                    .map(\.record),
                deletedIDs: page.deletions.map(\.recordID),
                changeToken: page.changeToken
            )
            moreComing = page.moreComing
        }
        zoneStates[zoneID] = state
        return Array(state.records.values)
    }

    /// The pure half of one delta page. Extracted because the page type itself
    /// cannot be faked — neither `CKDatabase.RecordZoneChange.Modification` nor
    /// `CKServerChangeToken` has a public initializer — so this is the only
    /// seam where the delta bookkeeping is directly testable.
    nonisolated static func merging(
        _ state: ZoneState,
        changed: [CKRecord],
        deletedIDs: [CKRecord.ID],
        changeToken: CKServerChangeToken?
    ) -> ZoneState {
        var state = state
        for record in changed {
            state.records[record.recordID] = record
        }
        for id in deletedIDs {
            state.records[id] = nil
        }
        state.changeToken = changeToken
        return state
    }

    nonisolated static func apply(_ fields: [String: Any], to record: CKRecord) {
        for (key, value) in fields {
            switch value {
            case let value as String: record[key] = value as CKRecordValue
            case let value as Int: record[key] = value as NSNumber
            case let value as Double: record[key] = value as NSNumber
            case let value as Date: record[key] = value as NSDate
            case let value as Data: record[key] = value as NSData
            default: break
            }
        }
    }

    nonisolated static func decodeDevice(_ record: CKRecord) -> ICloudUsageDevice? {
        guard record.recordType == ICloudUsageRecordSchema.deviceRecordType,
              (record["schemaVersion"] as? NSNumber)?.intValue == ICloudUsageDevice.schemaVersion,
              let rawID = record["deviceID"] as? String,
              let id = UUID(uuidString: rawID),
              let name = record["deviceName"] as? String,
              let lastSeenAt = record["lastSeenAt"] as? Date else {
            return nil
        }
        return ICloudUsageDevice(id: id, name: name, lastSeenAt: lastSeenAt)
    }

    nonisolated static func decodeRollup(_ record: CKRecord) -> ICloudDailyUsageRollup? {
        guard record.recordType == ICloudUsageRecordSchema.rollupRecordType,
              (record["schemaVersion"] as? NSNumber)?.intValue == ICloudDailyUsageRollup.schemaVersion,
              let rawDeviceID = record["deviceID"] as? String,
              let deviceID = UUID(uuidString: rawDeviceID),
              let rawProvider = record["provider"] as? String,
              let provider = ServiceType(rawValue: rawProvider),
              let rawDay = record["day"] as? String,
              let day = ICloudUsageRecordSchema.date(fromDayString: rawDay),
              let input = (record["inputTokens"] as? NSNumber)?.intValue,
              let output = (record["outputTokens"] as? NSNumber)?.intValue,
              let cacheRead = (record["cacheReadTokens"] as? NSNumber)?.intValue,
              let cost = (record["estimatedCostUSD"] as? NSNumber)?.doubleValue,
              let quotaData = record["quotaSnapshots"] as? Data,
              let updatedAt = record["updatedAt"] as? Date else {
            return nil
        }
        let cacheCreation = (record["cacheCreationTokens"] as? NSNumber)?.intValue ?? 0
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let quotaSnapshots = try? decoder.decode([ICloudQuotaSnapshot].self, from: quotaData) else {
            return nil
        }
        return ICloudDailyUsageRollup(
            deviceID: deviceID,
            provider: provider,
            day: day,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            estimatedCostUSD: cost,
            quotaSnapshots: quotaSnapshots,
            updatedAt: updatedAt
        )
    }

    private func zoneName(for deviceID: UUID) -> String {
        Self.zonePrefix + deviceID.uuidString
    }

    /// Constructing a CKContainer can validate entitlements. Keep even that
    /// work behind the opt-in service guard so disabled is truly inert.
    private func privateDatabase() -> CKDatabase {
        CKContainer(identifier: Self.containerIdentifier).privateCloudDatabase
    }
}

/// Turns CloudKit's per-record result map into an all-or-nothing page. A single
/// failed record makes the service fall back to local totals instead of showing
/// a plausible-looking partial aggregate.
nonisolated enum CloudKitResultCollector {
    static func values<Key: Hashable, Value>(
        from results: [Key: Result<Value, Error>]
    ) throws -> [Value] {
        try results.values.map { try $0.get() }
    }
}
