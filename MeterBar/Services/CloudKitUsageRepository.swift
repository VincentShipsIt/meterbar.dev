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

    private let notificationCenter: NotificationCenter
    private var accountChangeObserver: NSObjectProtocol?

    /// `notificationCenter` is injectable so tests can post `.CKAccountChanged`
    /// without touching the process-wide default center.
    ///
    /// Every zone's cached delta token and decoded records are only valid for
    /// whichever iCloud account was signed in when they were fetched. If the
    /// user switches accounts without quitting, `synchronize` would otherwise
    /// recreate the same-named zone in the new account while `fetchSnapshot`
    /// kept serving the previous account's cached records and resumed with its
    /// change token. There is no per-account subset worth keeping, so the
    /// whole cache is dropped rather than filtered.
    ///
    /// Registered synchronously here rather than via a follow-up `Task`: an
    /// actor initializer may assign its own stored properties directly, and
    /// doing so keeps the observer live for every notification posted after
    /// `init` returns instead of racing whichever caller posts first.
    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        accountChangeObserver = notificationCenter.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.invalidateForAccountChange() }
        }
    }

    deinit {
        if let accountChangeObserver {
            notificationCenter.removeObserver(accountChangeObserver)
        }
    }

    /// Drops every zone's cached records and delta token. Called on
    /// `CKAccountChanged`; also directly testable since the notification hop
    /// is otherwise fire-and-forget.
    func invalidateForAccountChange() {
        zoneStates = [:]
    }

    /// Test/diagnostic accessor for the number of zones with cached state.
    func cachedZoneCount() -> Int {
        zoneStates.count
    }

    /// Test seam: seeds cached zone state without a live CloudKit round trip.
    func setZoneStateForTesting(_ state: ZoneState, zoneID: CKRecordZone.ID) {
        zoneStates[zoneID] = state
    }

    func synchronize(
        device: ICloudUsageDevice,
        rollups: [ICloudDailyUsageRollup]
    ) async throws -> ICloudUsageRepositorySnapshot {
        let database = privateDatabase()
        let zone = CKRecordZone(zoneName: zoneName(for: device.id))
        let zoneResults = try await database.modifyRecordZones(saving: [zone], deleting: [])
        // CloudKit reports per-zone failures inside the result map rather than by
        // throwing, so an ignored `saveResults` would let the atomic record save
        // below proceed against a zone that was never actually created.
        _ = try CloudKitResultCollector.values(from: zoneResults.saveResults)

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

        // After `fetchSnapshot`, not before the save: `zoneStates` is empty on a
        // cold process until the fetch fills it, so pruning here lets the first
        // sync of a launch prune too. The snapshot needs no re-filtering —
        // everything dropped is older than `retentionDayCount`, which is already
        // outside the window `ICloudUsageAggregation.fold` renders.
        let snapshot = try await fetchSnapshot()
        await pruneExpiredRollups(in: zone.zoneID, now: Date())
        return snapshot
    }

    /// Deletes this Mac's own rollups that have aged out of `retentionDayCount`.
    ///
    /// Scoped to our own zone on purpose: every install prunes its own history,
    /// so a Mac that has been offline for months never has its records deleted
    /// by a peer that merely holds a newer clock.
    private func pruneExpiredRollups(in zoneID: CKRecordZone.ID, now: Date) async {
        guard let cached = zoneStates[zoneID]?.records.keys else { return }
        let expired = Self.expiredRollupRecordIDs(
            among: cached,
            now: now,
            retentionDayCount: ICloudUsageAggregation.retentionDayCount,
            calendar: .current
        )
        guard !expired.isEmpty else { return }

        // Non-atomic and best effort, unlike the save above: one stubborn record
        // must not block the rest of the prune, and housekeeping must never fail
        // the sync the user is waiting on. Only CloudKit-confirmed deletions
        // leave the cache, so anything that failed is retried next sync.
        guard let results = try? await privateDatabase().modifyRecords(
            saving: [],
            deleting: expired,
            savePolicy: .changedKeys,
            atomically: false
        ) else { return }
        for (recordID, result) in results.deleteResults where (try? result.get()) != nil {
            zoneStates[zoneID]?.records[recordID] = nil
        }
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

    /// Which of `recordIDs` fall outside the retention window ending on the
    /// local day containing `now`.
    ///
    /// Expiry is derived from the record *name* rather than the decoded body so
    /// that a rollup written by a future schema version — which `decodeRollup`
    /// returns `nil` for — still ages out instead of accumulating forever.
    nonisolated static func expiredRollupRecordIDs(
        among recordIDs: some Sequence<CKRecord.ID>,
        now: Date,
        retentionDayCount: Int,
        calendar: Calendar
    ) -> [CKRecord.ID] {
        // A misconfigured window fails closed rather than wiping the zone.
        guard retentionDayCount > 0,
              let cutoff = calendar.date(
                  byAdding: .day,
                  value: -(retentionDayCount - 1),
                  to: calendar.startOfDay(for: now)
              ) else {
            return []
        }
        return recordIDs.filter { recordID in
            guard let day = rollupDay(fromRecordName: recordID.recordName, calendar: calendar) else {
                return false
            }
            // Compared by calendar day rather than by raw `Date` ordering: in a
            // zone whose DST transition falls at local midnight, `startOfDay`
            // for the transitioning day lands on 01:00 (midnight does not
            // exist), so `cutoff` can carry a non-zero wall-clock time while
            // `rollupDay` always reconstructs an exact midnight. Comparing
            // instants directly would then misclassify the cutoff's own day —
            // the oldest day the window is supposed to keep — as expired.
            return calendar.compare(day, to: cutoff, toGranularity: .day) == .orderedAscending
        }
    }

    /// Inverse of `ICloudDailyUsageRollup.recordName(provider:day:calendar:)`.
    ///
    /// Strict on purpose. Deleting from the user's iCloud is irreversible, so
    /// anything that is not exactly `rollup-<provider>-<yyyy-MM-dd>` returns
    /// `nil` and is therefore never a deletion candidate — the device record and
    /// any record type added later stay inert. The provider segment is skipped
    /// rather than parsed because raw values contain spaces and hyphens.
    nonisolated static func rollupDay(fromRecordName name: String, calendar: Calendar) -> Date? {
        let prefix = "rollup-"
        let dayKeyLength = 10
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = name.dropFirst(prefix.count)
        // Needs at least one provider character plus its separator.
        guard suffix.count > dayKeyLength + 1,
              suffix.dropLast(dayKeyLength).last == "-" else {
            return nil
        }
        let parts = suffix.suffix(dayKeyLength)
            .split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
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
