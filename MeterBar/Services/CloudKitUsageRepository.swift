import CloudKit
import Foundation
import MeterBarShared

/// Production transport for MeterBar's private CloudKit database. Each install
/// owns one custom zone, tying its stable UUID to the deletion boundary.
actor CloudKitUsageRepository: ICloudUsageRepository {
    static let containerIdentifier = "iCloud.dev.meterbar.app"
    static let zonePrefix = "MeterBarUsage-"

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
        apply(ICloudUsageRecordSchema.fields(for: device), to: deviceRecord)

        let rollupRecords = try rollups.map { rollup -> CKRecord in
            let record = CKRecord(
                recordType: ICloudUsageRecordSchema.rollupRecordType,
                recordID: CKRecord.ID(recordName: rollup.recordName, zoneID: zone.zoneID)
            )
            apply(try ICloudUsageRecordSchema.fields(for: rollup), to: record)
            return record
        }
        _ = try await database.modifyRecords(
            saving: [deviceRecord] + rollupRecords,
            deleting: [],
            savePolicy: .changedKeys,
            atomically: true
        )

        return try await fetchSnapshot()
    }

    func removeDevice(id: UUID) async throws {
        let database = privateDatabase()
        let zoneID = CKRecordZone.ID(zoneName: zoneName(for: id), ownerName: CKCurrentUserDefaultName)
        _ = try await database.modifyRecordZones(saving: [], deleting: [zoneID])
    }

    private func fetchSnapshot() async throws -> ICloudUsageRepositorySnapshot {
        let database = privateDatabase()
        let zones = try await database.allRecordZones()
            .filter { $0.zoneID.zoneName.hasPrefix(Self.zonePrefix) }
        var devices: [ICloudUsageDevice] = []
        var rollups: [ICloudDailyUsageRollup] = []

        for zone in zones {
            let zoneRecords = try await records(in: zone.zoneID)
            for record in zoneRecords {
                if let device = decodeDevice(record) {
                    devices.append(device)
                } else if let rollup = decodeRollup(record) {
                    rollups.append(rollup)
                }
            }
        }
        return ICloudUsageRepositorySnapshot(devices: devices, rollups: rollups)
    }

    private func records(in zoneID: CKRecordZone.ID) async throws -> [CKRecord] {
        let database = privateDatabase()
        var records: [CKRecord] = []
        var changeToken: CKServerChangeToken?
        var moreComing = true
        while moreComing {
            let page = try await database.recordZoneChanges(
                inZoneWith: zoneID,
                since: changeToken
            )
            records += page.modificationResultsByID.values.compactMap {
                try? $0.get().record
            }
            changeToken = page.changeToken
            moreComing = page.moreComing
        }
        return records
    }

    private func apply(_ fields: [String: Any], to record: CKRecord) {
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

    private func decodeDevice(_ record: CKRecord) -> ICloudUsageDevice? {
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

    private func decodeRollup(_ record: CKRecord) -> ICloudDailyUsageRollup? {
        guard record.recordType == ICloudUsageRecordSchema.rollupRecordType,
              (record["schemaVersion"] as? NSNumber)?.intValue == ICloudDailyUsageRollup.schemaVersion,
              let rawDeviceID = record["deviceID"] as? String,
              let deviceID = UUID(uuidString: rawDeviceID),
              let rawProvider = record["provider"] as? String,
              let provider = ServiceType(rawValue: rawProvider),
              let day = record["day"] as? Date,
              let input = (record["inputTokens"] as? NSNumber)?.intValue,
              let output = (record["outputTokens"] as? NSNumber)?.intValue,
              let cacheRead = (record["cacheReadTokens"] as? NSNumber)?.intValue,
              let cost = (record["estimatedCostUSD"] as? NSNumber)?.doubleValue,
              let quotaData = record["quotaSnapshots"] as? Data,
              let updatedAt = record["updatedAt"] as? Date else {
            return nil
        }
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
