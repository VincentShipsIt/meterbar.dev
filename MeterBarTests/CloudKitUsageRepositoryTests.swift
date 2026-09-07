import CloudKit
import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class CloudKitUsageRepositoryTests: XCTestCase {
    private let deviceID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7))
    private let zoneID = CKRecordZone.ID(
        zoneName: CloudKitUsageRepository.zonePrefix + "test",
        ownerName: CKCurrentUserDefaultName
    )

    // MARK: - Record naming

    func testRecordNameSeparatesLocalDaysAcrossSpringForward() {
        let calendar = calendar(for: "Europe/London")
        // Local midnight either side of the 2026-03-29 transition. Both instants
        // divide to the same epoch day because the day between them is 23 hours.
        let springForward = Date(timeIntervalSince1970: 1_774_742_400)
        let dayAfter = Date(timeIntervalSince1970: 1_774_825_200)
        XCTAssertEqual(
            Int(springForward.timeIntervalSince1970) / 86_400,
            Int(dayAfter.timeIntervalSince1970) / 86_400
        )

        let first = ICloudDailyUsageRollup.recordName(
            provider: .codexCli,
            day: springForward,
            calendar: calendar
        )
        let second = ICloudDailyUsageRollup.recordName(
            provider: .codexCli,
            day: dayAfter,
            calendar: calendar
        )

        XCTAssertEqual(first, "rollup-\(ServiceType.codexCli.rawValue)-2026-03-29")
        XCTAssertEqual(second, "rollup-\(ServiceType.codexCli.rawValue)-2026-03-30")
    }

    func testRecordNameUsesLocalDayEastOfUTC() {
        let calendar = calendar(for: "Asia/Tokyo")
        // Local midnight on 2026-03-30 in Tokyo is still 2026-03-29 in UTC.
        let localMidnight = Date(timeIntervalSince1970: 1_774_796_400)

        XCTAssertEqual(
            ICloudDailyUsageRollup.recordName(
                provider: .claudeCode,
                day: localMidnight,
                calendar: calendar
            ),
            "rollup-\(ServiceType.claudeCode.rawValue)-2026-03-30"
        )
    }

    func testRecordNamesForDistinctProvidersDoNotCollideOnTheSameDay() {
        let calendar = calendar(for: "UTC")
        let day = Date(timeIntervalSince1970: 1_774_742_400)

        XCTAssertNotEqual(
            ICloudDailyUsageRollup.recordName(provider: .codexCli, day: day, calendar: calendar),
            ICloudDailyUsageRollup.recordName(provider: .claudeCode, day: day, calendar: calendar)
        )
    }

    // MARK: - Result collection

    func testZoneDeletionFailureIsSurfacedFromTheResultMap() {
        let results: [CKRecordZone.ID: Result<Void, Error>] = [
            zoneID: .failure(TestError.rejected)
        ]

        XCTAssertThrowsError(try CloudKitResultCollector.values(from: results)) { error in
            XCTAssertEqual(error as? TestError, .rejected)
        }
    }

    func testSuccessfulZoneDeletionCollectsWithoutThrowing() throws {
        let results: [CKRecordZone.ID: Result<Void, Error>] = [zoneID: .success(())]

        XCTAssertEqual(try CloudKitResultCollector.values(from: results).count, 1)
    }

    // MARK: - Delta bookkeeping

    func testMergingAppliesChangedRecordsAndCarriesTheToken() {
        let first = record(named: "device")
        let second = record(named: "rollup-a")

        let state = CloudKitUsageRepository.merging(
            CloudKitUsageRepository.ZoneState(),
            changed: [first, second],
            deletedIDs: [],
            changeToken: nil
        )

        XCTAssertEqual(Set(state.records.keys), [first.recordID, second.recordID])
        XCTAssertNil(state.changeToken)
    }

    func testMergingRemovesDeletedRecordsFromTheCachedZone() {
        let kept = record(named: "device")
        let removed = record(named: "rollup-a")
        let seeded = CloudKitUsageRepository.merging(
            CloudKitUsageRepository.ZoneState(),
            changed: [kept, removed],
            deletedIDs: [],
            changeToken: nil
        )

        let state = CloudKitUsageRepository.merging(
            seeded,
            changed: [],
            deletedIDs: [removed.recordID],
            changeToken: nil
        )

        XCTAssertEqual(Array(state.records.keys), [kept.recordID])
    }

    func testMergingKeepsRecordsFromEarlierPagesOfTheSameZone() {
        let firstPage = CloudKitUsageRepository.merging(
            CloudKitUsageRepository.ZoneState(),
            changed: [record(named: "rollup-a")],
            deletedIDs: [],
            changeToken: nil
        )

        let secondPage = CloudKitUsageRepository.merging(
            firstPage,
            changed: [record(named: "rollup-b")],
            deletedIDs: [],
            changeToken: nil
        )

        XCTAssertEqual(secondPage.records.count, 2)
    }

    func testMergingReplacesAnUpdatedRecordRatherThanDuplicatingIt() {
        let original = record(named: "device")
        original["deviceName"] = "Studio" as CKRecordValue
        let seeded = CloudKitUsageRepository.merging(
            CloudKitUsageRepository.ZoneState(),
            changed: [original],
            deletedIDs: [],
            changeToken: nil
        )
        let updated = record(named: "device")
        updated["deviceName"] = "Laptop" as CKRecordValue

        let state = CloudKitUsageRepository.merging(
            seeded,
            changed: [updated],
            deletedIDs: [],
            changeToken: nil
        )

        XCTAssertEqual(state.records.count, 1)
        XCTAssertEqual(state.records[updated.recordID]?["deviceName"] as? String, "Laptop")
    }

    // MARK: - Encode / decode round trips

    func testDeviceRoundTripsThroughRecordFields() {
        let device = ICloudUsageDevice(
            id: deviceID,
            name: "Studio",
            lastSeenAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let record = CKRecord(
            recordType: ICloudUsageRecordSchema.deviceRecordType,
            recordID: CKRecord.ID(recordName: "device", zoneID: zoneID)
        )
        CloudKitUsageRepository.apply(ICloudUsageRecordSchema.fields(for: device), to: record)

        XCTAssertEqual(CloudKitUsageRepository.decodeDevice(record), device)
        XCTAssertNil(CloudKitUsageRepository.decodeRollup(record))
    }

    func testRollupRoundTripsThroughRecordFieldsIncludingQuotaSnapshots() throws {
        let rollup = sampleRollup()
        let record = CKRecord(
            recordType: ICloudUsageRecordSchema.rollupRecordType,
            recordID: CKRecord.ID(recordName: rollup.recordName, zoneID: zoneID)
        )
        CloudKitUsageRepository.apply(try ICloudUsageRecordSchema.fields(for: rollup), to: record)

        XCTAssertEqual(CloudKitUsageRepository.decodeRollup(record), rollup)
        XCTAssertNil(CloudKitUsageRepository.decodeDevice(record))
    }

    func testRollupFromAFutureSchemaVersionIsIgnoredRatherThanPartiallyDecoded() throws {
        let record = CKRecord(
            recordType: ICloudUsageRecordSchema.rollupRecordType,
            recordID: CKRecord.ID(recordName: "rollup-future", zoneID: zoneID)
        )
        CloudKitUsageRepository.apply(
            try ICloudUsageRecordSchema.fields(for: sampleRollup()),
            to: record
        )
        record["schemaVersion"] = (ICloudDailyUsageRollup.schemaVersion + 1) as NSNumber

        XCTAssertNil(CloudKitUsageRepository.decodeRollup(record))
    }

    func testRollupMissingARequiredFieldDecodesToNil() throws {
        let record = CKRecord(
            recordType: ICloudUsageRecordSchema.rollupRecordType,
            recordID: CKRecord.ID(recordName: "rollup-partial", zoneID: zoneID)
        )
        CloudKitUsageRepository.apply(
            try ICloudUsageRecordSchema.fields(for: sampleRollup()),
            to: record
        )
        record["quotaSnapshots"] = nil

        XCTAssertNil(CloudKitUsageRepository.decodeRollup(record))
    }

    // MARK: - Retention pruning

    /// 2026-09-02T00:00:00Z. With `retentionDayCount = 90` the oldest retained
    /// local day is 2026-06-05, so 2026-06-04 is the first deletion candidate.
    private static let retentionNow = Date(timeIntervalSince1970: 1_788_307_200)

    func testRollupOnTheOldestRetainedDayIsKept() {
        let expired = CloudKitUsageRepository.expiredRollupRecordIDs(
            among: [recordID("rollup-\(ServiceType.cursor.rawValue)-2026-06-05")],
            now: Self.retentionNow,
            retentionDayCount: ICloudUsageAggregation.retentionDayCount,
            calendar: calendar(for: "UTC")
        )

        XCTAssertTrue(expired.isEmpty)
    }

    func testRollupOneDayBeyondRetentionIsDeleted() {
        let stale = recordID("rollup-\(ServiceType.cursor.rawValue)-2026-06-04")

        let expired = CloudKitUsageRepository.expiredRollupRecordIDs(
            among: [stale],
            now: Self.retentionNow,
            retentionDayCount: ICloudUsageAggregation.retentionDayCount,
            calendar: calendar(for: "UTC")
        )

        XCTAssertEqual(expired, [stale])
    }

    func testRetentionWindowIsWiderThanTheVisibleWindow() {
        // The prune must never be able to reach a day the dashboard can render,
        // so widening `visibleDayCount` later cannot retroactively destroy data.
        XCTAssertGreaterThan(
            ICloudUsageAggregation.retentionDayCount,
            ICloudUsageAggregation.visibleDayCount
        )
    }

    func testRetentionCutoffFollowsTheLocalDayNotUTC() {
        // 2026-09-01T23:00:00Z is already 2026-09-02 in Tokyo, which moves the
        // cutoff a day later than a UTC reading of the same instant would.
        let now = Date(timeIntervalSince1970: 1_788_303_600)
        let borderline = recordID("rollup-\(ServiceType.grok.rawValue)-2026-06-04")

        XCTAssertEqual(
            CloudKitUsageRepository.expiredRollupRecordIDs(
                among: [borderline],
                now: now,
                retentionDayCount: ICloudUsageAggregation.retentionDayCount,
                calendar: calendar(for: "Asia/Tokyo")
            ),
            [borderline]
        )
        XCTAssertTrue(
            CloudKitUsageRepository.expiredRollupRecordIDs(
                among: [borderline],
                now: now,
                retentionDayCount: ICloudUsageAggregation.retentionDayCount,
                calendar: calendar(for: "UTC")
            ).isEmpty
        )
    }

    func testRetentionSpansTheSameNumberOfLocalDaysAcrossADSTTransition() {
        // Europe/London springs forward inside this window. Counting by calendar
        // days rather than by 86,400-second strides keeps the boundary on the
        // day it names instead of sliding an hour short.
        let calendar = calendar(for: "Europe/London")
        let now = Date(timeIntervalSince1970: 1_774_915_200) // 2026-03-31T00:00:00Z
        let oldestRetained = recordID("rollup-\(ServiceType.claudeCode.rawValue)-2026-01-01")
        let firstExpired = recordID("rollup-\(ServiceType.claudeCode.rawValue)-2025-12-31")

        let expired = CloudKitUsageRepository.expiredRollupRecordIDs(
            among: [oldestRetained, firstExpired],
            now: now,
            retentionDayCount: 90,
            calendar: calendar
        )

        XCTAssertEqual(expired, [firstExpired])
    }

    func testDeviceRecordIsNeverADeletionCandidate() {
        XCTAssertTrue(
            CloudKitUsageRepository.expiredRollupRecordIDs(
                among: [recordID("device")],
                now: Self.retentionNow,
                retentionDayCount: 1,
                calendar: calendar(for: "UTC")
            ).isEmpty
        )
    }

    func testUnrecognisedRecordNamesFailClosedAndAreNeverDeleted() {
        // Deleting from the user's iCloud is irreversible, so anything that is
        // not exactly `rollup-<provider>-<yyyy-MM-dd>` has to survive.
        let names = [
            "device",
            "rollup",
            "rollup-",
            "rollup-2026-06-04",                 // no provider segment
            "rollup-Cursor-2026-6-4",            // unpadded components
            "rollup-Cursor-2026-06",             // truncated day
            "rollup-Cursor-20260604",            // no separators
            "rollup-Cursor-abcd-ef-gh",          // non-numeric
            "rollup-Cursor-2026-06-04-extra",    // trailing junk
            "quota-Cursor-2026-06-04",           // different prefix
        ]

        let expired = CloudKitUsageRepository.expiredRollupRecordIDs(
            among: names.map(recordID),
            now: Self.retentionNow,
            retentionDayCount: 1,
            calendar: calendar(for: "UTC")
        )

        XCTAssertTrue(expired.isEmpty, "unexpected deletion candidates: \(expired)")
        for name in names {
            XCTAssertNil(
                CloudKitUsageRepository.rollupDay(
                    fromRecordName: name,
                    calendar: calendar(for: "UTC")
                ),
                "unexpectedly parsed \(name)"
            )
        }
        // CloudKit rejects an empty record name, so this one is only reachable
        // through the string parser rather than through a CKRecord.ID.
        XCTAssertNil(
            CloudKitUsageRepository.rollupDay(fromRecordName: "", calendar: calendar(for: "UTC"))
        )
    }

    func testProviderNamesContainingSpacesStillParse() {
        // `Claude Code` and `Codex CLI` are raw values with a space, and the
        // parser must key off the trailing date rather than splitting the name.
        for provider in [ServiceType.claudeCode, .codexCli, .openRouter] {
            let name = ICloudDailyUsageRollup.recordName(
                provider: provider,
                day: Date(timeIntervalSince1970: 1_780_000_000),
                calendar: calendar(for: "UTC")
            )

            XCTAssertNotNil(
                CloudKitUsageRepository.rollupDay(
                    fromRecordName: name,
                    calendar: calendar(for: "UTC")
                ),
                "failed to parse \(name)"
            )
        }
    }

    func testRollupDayRoundTripsTheNameProducedByRecordName() {
        let calendar = calendar(for: "Europe/London")
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000))
        let name = ICloudDailyUsageRollup.recordName(
            provider: .cursor,
            day: day,
            calendar: calendar
        )

        XCTAssertEqual(
            CloudKitUsageRepository.rollupDay(fromRecordName: name, calendar: calendar),
            day
        )
    }

    func testEmptyZoneCacheProducesNoDeletions() {
        XCTAssertTrue(
            CloudKitUsageRepository.expiredRollupRecordIDs(
                among: [CKRecord.ID](),
                now: Self.retentionNow,
                retentionDayCount: ICloudUsageAggregation.retentionDayCount,
                calendar: calendar(for: "UTC")
            ).isEmpty
        )
    }

    func testNonPositiveRetentionDeletesNothing() {
        // A misconfigured window must fail closed rather than wipe the zone.
        for retention in [0, -1] {
            XCTAssertTrue(
                CloudKitUsageRepository.expiredRollupRecordIDs(
                    among: [recordID("rollup-\(ServiceType.cursor.rawValue)-2020-01-01")],
                    now: Self.retentionNow,
                    retentionDayCount: retention,
                    calendar: calendar(for: "UTC")
                ).isEmpty
            )
        }
    }

    // MARK: - Helpers

    private func calendar(for identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    private func record(named name: String) -> CKRecord {
        CKRecord(
            recordType: ICloudUsageRecordSchema.deviceRecordType,
            recordID: CKRecord.ID(recordName: name, zoneID: zoneID)
        )
    }

    private func sampleRollup() -> ICloudDailyUsageRollup {
        ICloudDailyUsageRollup(
            deviceID: deviceID,
            provider: .codexCli,
            day: Date(timeIntervalSince1970: 1_799_971_200),
            inputTokens: 100,
            outputTokens: 20,
            cacheCreationTokens: 30,
            cacheReadTokens: 40,
            estimatedCostUSD: 1.25,
            quotaSnapshots: [
                ICloudQuotaSnapshot(
                    provider: .codexCli,
                    accountIdentity: "account",
                    capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    windows: [
                        ICloudQuotaWindow(kind: "weekly", used: 12, total: 100, resetAt: nil)
                    ]
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private enum TestError: Error, Equatable { case rejected }
}
