import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class ICloudUsageAggregationTests: XCTestCase {
    private let firstDeviceID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    private let secondDeviceID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
    private let day = Date(timeIntervalSince1970: 1_799_971_200)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFoldSumsDailyUsageAcrossDevices() {
        let result = ICloudUsageAggregation.fold(
            devices: [device(firstDeviceID, name: "Studio"), device(secondDeviceID, name: "Laptop")],
            rollups: [
                rollup(firstDeviceID, input: 100, output: 20, cost: 1.25),
                rollup(secondDeviceID, input: 40, output: 10, cost: 0.75),
            ],
            now: now
        )

        XCTAssertEqual(result.totalTokens, 170)
        XCTAssertEqual(result.totalCostUSD, 2, accuracy: 0.000_001)
        XCTAssertEqual(result.contributingDeviceIDs, [firstDeviceID, secondDeviceID])
        XCTAssertEqual(result.costSummary.dailyUsage.count, 1)
    }

    func testSameAccountQuotaUsesLatestSnapshotInsteadOfSumming() throws {
        let old = quota(account: "acct-shared", used: 90, capturedAt: now.addingTimeInterval(-60))
        let latest = quota(account: "acct-shared", used: 12, capturedAt: now)
        let result = ICloudUsageAggregation.fold(
            devices: [device(firstDeviceID), device(secondDeviceID)],
            rollups: [
                rollup(firstDeviceID, quota: [old]),
                rollup(secondDeviceID, quota: [latest]),
            ],
            now: now
        )

        let snapshot = try XCTUnwrap(result.quotaSnapshots.first)
        XCTAssertEqual(result.quotaSnapshots.count, 1)
        XCTAssertEqual(snapshot.windows.first?.used, 12)
    }

    func testRemovedDeviceAndItsRollupsDoNotContribute() {
        let result = ICloudUsageAggregation.fold(
            devices: [device(firstDeviceID)],
            rollups: [rollup(firstDeviceID, input: 10), rollup(secondDeviceID, input: 999)],
            now: now
        )

        XCTAssertEqual(result.totalTokens, 10)
        XCTAssertEqual(result.contributingDeviceIDs, [firstDeviceID])
    }

    func testLastWriterWinsForClockSkewedDuplicateKey() {
        let newest = rollup(firstDeviceID, input: 7, updatedAt: now.addingTimeInterval(120))
        let staleArrival = rollup(firstDeviceID, input: 900, updatedAt: now)

        let result = ICloudUsageAggregation.fold(
            devices: [device(firstDeviceID)],
            rollups: [newest, staleArrival],
            now: now
        )

        XCTAssertEqual(result.totalTokens, 7)
    }

    func testOfflineDeviceAgesOutOfActiveListWithoutLosingHistory() {
        let offline = ICloudUsageDevice(
            id: secondDeviceID,
            name: "Travel Mac",
            lastSeenAt: now.addingTimeInterval(-ICloudUsageAggregation.activeDeviceInterval - 1)
        )
        let result = ICloudUsageAggregation.fold(
            devices: [device(firstDeviceID), offline],
            rollups: [rollup(firstDeviceID, input: 10), rollup(secondDeviceID, input: 20)],
            now: now
        )

        XCTAssertEqual(result.activeDevices.map(\.id), [firstDeviceID])
        XCTAssertEqual(result.totalTokens, 30)
        XCTAssertEqual(result.devices.count, 2)
    }

    func testHistoryOutsideVisibleWindowDoesNotInflateDashboardTotals() throws {
        let calendar = Calendar(identifier: .gregorian)
        let oldDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: day))
        let oldRollup = ICloudDailyUsageRollup(
            deviceID: firstDeviceID,
            provider: .codexCli,
            day: oldDay,
            inputTokens: 500,
            outputTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: 5,
            quotaSnapshots: [],
            updatedAt: now
        )
        let result = ICloudUsageAggregation.fold(
            devices: [device(firstDeviceID)],
            rollups: [rollup(firstDeviceID, input: 10), oldRollup],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(result.totalTokens, 10)
        XCTAssertEqual(result.rollups.count, 2)
    }

    func testSchemaContainsOnlyReviewedAggregateFields() throws {
        let payload = try ICloudUsageRecordSchema.fields(for: rollup(firstDeviceID, input: 42, cost: 1.5))

        XCTAssertEqual(Set(payload.keys), ICloudUsageRecordSchema.rollupFieldNames)
        XCTAssertFalse(payload.keys.contains { key in
            let forbiddenNames = [
                "rawLog", "credential", "accessToken", "refreshToken", "cookie", "path", "project", "session", "model",
            ]
            return forbiddenNames.contains {
                key.localizedCaseInsensitiveContains($0)
            }
        })
        let quotaData = try XCTUnwrap(payload["quotaSnapshots"] as? Data)
        let quotaObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: quotaData) as? [[String: Any]]
        )
        XCTAssertTrue(quotaObject.allSatisfy {
            Set($0.keys) == ["provider", "accountIdentity", "capturedAt", "windows"]
        })
    }

    func testFeatureOffMakesZeroRepositoryCalls() async {
        let repository = RepositorySpy()
        let settings = ICloudUsageSettingsStore(userDefaults: isolatedDefaults())
        let service = ICloudUsageAggregationService(settings: settings, repository: repository)

        await service.sync(localSummary: summary(), quotaSnapshots: [])

        let callCount = await repository.callCount
        XCTAssertEqual(callCount, 0)
        XCTAssertNil(service.aggregate)
    }

    func testICloudFailureKeepsLocalOnlyFallback() async {
        let repository = RepositorySpy(error: TestError.unavailable)
        let settings = ICloudUsageSettingsStore(userDefaults: isolatedDefaults())
        settings.setEnabled(true)
        let service = ICloudUsageAggregationService(settings: settings, repository: repository)

        await service.sync(localSummary: summary(), quotaSnapshots: [])

        XCTAssertNil(service.aggregate)
        XCTAssertEqual(service.lastError, "iCloud usage sync is unavailable. Local totals are still shown.")
    }

    func testDeviceIdentifierAndNamePersistAcrossStoreReload() {
        let defaults = isolatedDefaults()
        let first = ICloudUsageSettingsStore(userDefaults: defaults, defaultDeviceName: { "Studio" })
        first.setDeviceName("Build Mac")
        let second = ICloudUsageSettingsStore(userDefaults: defaults, defaultDeviceName: { "Ignored" })

        XCTAssertEqual(second.deviceID, first.deviceID)
        XCTAssertEqual(second.deviceName, "Build Mac")
        XCTAssertEqual(second.recordZoneName, "MeterBarUsage-\(first.deviceID.uuidString)")
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "ICloudUsageAggregationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? UserDefaults()
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func device(_ id: UUID, name: String = "Mac") -> ICloudUsageDevice {
        ICloudUsageDevice(id: id, name: name, lastSeenAt: now)
    }

    private func quota(account: String, used: Double, capturedAt: Date) -> ICloudQuotaSnapshot {
        ICloudQuotaSnapshot(
            provider: .codexCli,
            accountIdentity: account,
            capturedAt: capturedAt,
            windows: [ICloudQuotaWindow(kind: "weekly", used: used, total: 100, resetAt: nil)]
        )
    }

    private func rollup(
        _ deviceID: UUID,
        input: Int = 0,
        output: Int = 0,
        cost: Double = 0,
        quota: [ICloudQuotaSnapshot] = [],
        updatedAt: Date? = nil
    ) -> ICloudDailyUsageRollup {
        ICloudDailyUsageRollup(
            deviceID: deviceID,
            provider: .codexCli,
            day: day,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: 0,
            estimatedCostUSD: cost,
            quotaSnapshots: quota,
            updatedAt: updatedAt ?? now
        )
    }

    private func summary() -> CostSummary {
        CostSummary(
            costs: [],
            totalCostUSD: 1,
            totalTokens: 42,
            periodDays: 30,
            dailyUsage: [
                DailyTokenUsage(
                    date: day,
                    provider: .codexCli,
                    inputTokens: 42,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 1
                )
            ]
        )
    }

    private enum TestError: Error { case unavailable }
}

private actor RepositorySpy: ICloudUsageRepository {
    private(set) var callCount = 0
    let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func synchronize(device: ICloudUsageDevice, rollups: [ICloudDailyUsageRollup]) async throws
        -> ICloudUsageRepositorySnapshot {
        callCount += 1
        if let error { throw error }
        return ICloudUsageRepositorySnapshot(devices: [device], rollups: rollups)
    }

    func removeDevice(id: UUID) async throws {
        callCount += 1
        if let error { throw error }
    }
}
