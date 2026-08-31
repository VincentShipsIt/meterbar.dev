import Combine
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

    func testOneMacRoundTripPreservesCacheCreationTokenParity() throws {
        let localCost = TokenCost(
            provider: .claudeCode,
            inputTokens: 100,
            outputTokens: 20,
            cacheCreationTokens: 30,
            cacheReadTokens: 40,
            estimatedCostUSD: 1.25,
            sessionCount: 1,
            periodStart: day,
            periodEnd: day
        )
        let localSummary = CostSummary(
            costs: [localCost],
            totalCostUSD: 1.25,
            totalTokens: localCost.totalTokens,
            periodDays: 1,
            dailyUsage: [
                DailyTokenUsage(
                    date: day,
                    provider: .claudeCode,
                    inputTokens: 100,
                    outputTokens: 20,
                    cacheCreationTokens: 30,
                    cacheReadTokens: 40,
                    estimatedCostUSD: 1.25
                )
            ]
        )

        let rollups = ICloudUsageAggregation.localRollups(
            deviceID: firstDeviceID,
            summary: localSummary,
            quotaSnapshots: [],
            now: now
        )
        let aggregate = ICloudUsageAggregation.fold(
            devices: [device(firstDeviceID)],
            rollups: rollups,
            now: now
        )
        let aggregateCost = try XCTUnwrap(aggregate.costSummary.costs.first)

        XCTAssertEqual(aggregateCost.cacheCreationTokens, localCost.cacheCreationTokens)
        XCTAssertEqual(aggregate.totalTokens, localSummary.totalTokens)
        XCTAssertEqual(aggregate.totalCostUSD, localSummary.totalCostUSD, accuracy: 0.000_001)
    }

    func testDemoOneMacRoundTripPreservesTokenProviderParity() {
        let calendar = Calendar(identifier: .gregorian)
        let providers = Set(ServiceType.allCases.filter(\.writesLocalTokenLogs))
        let localSummary = DemoData.costSummary(now: now, calendar: calendar).filtered(to: providers)
        let rollups = ICloudUsageAggregation.localRollups(
            deviceID: firstDeviceID,
            summary: localSummary,
            quotaSnapshots: [],
            now: now,
            calendar: calendar
        )
        let aggregate = ICloudUsageAggregation.fold(
            devices: [device(firstDeviceID)],
            rollups: rollups,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(aggregate.totalTokens, localSummary.totalTokens)
        XCTAssertEqual(aggregate.totalCostUSD, localSummary.totalCostUSD, accuracy: 0.000_001)
    }

    @MainActor
    func testFirstOptInPreparesLegacyDailyRowsBeforePublishing() async throws {
        let repository = RepositorySpy()
        let settings = ICloudUsageSettingsStore(userDefaults: isolatedDefaults())
        settings.setEnabled(true)
        let legacySummary = summary(dailyUsage: [try legacyDailyUsage()])
        let authoritativeSummary = summary(dailyUsage: [
            DailyTokenUsage(
                date: day,
                provider: .codexCli,
                inputTokens: 42,
                outputTokens: 0,
                cacheCreationTokens: 7,
                cacheReadTokens: 0,
                estimatedCostUSD: 1
            ),
        ])
        var preparationCount = 0
        let service = ICloudUsageAggregationService(
            settings: settings,
            repository: repository,
            prepareLocalSummary: { candidate in
                preparationCount += 1
                XCTAssertFalse(candidate?.hasAuthoritativeDailyCacheCreationTokens ?? true)
                return .completed(authoritativeSummary)
            }
        )

        await service.sync(localSummary: legacySummary, quotaSnapshots: [])

        let published = await repository.synchronizedRollups
        XCTAssertEqual(preparationCount, 1)
        XCTAssertEqual(published.first?.cacheCreationTokens, 7)
    }

    @MainActor
    func testLegacyDailyRowsAreNotPublishedWhenPreparationCannotComplete() async throws {
        let repository = RepositorySpy()
        let settings = ICloudUsageSettingsStore(userDefaults: isolatedDefaults())
        settings.setEnabled(true)
        let legacySummary = summary(dailyUsage: [try legacyDailyUsage()])
        let service = ICloudUsageAggregationService(
            settings: settings,
            repository: repository,
            prepareLocalSummary: { _ in .failed }
        )

        await service.sync(localSummary: legacySummary, quotaSnapshots: [])

        let callCount = await repository.callCount
        XCTAssertEqual(callCount, 0)
        XCTAssertNotNil(service.lastError)
    }

    @MainActor
    func testNilSummaryRequiresCompletedPreparationBeforeRepositoryAccess() async {
        let repository = RepositorySpy()
        let settings = ICloudUsageSettingsStore(userDefaults: isolatedDefaults())
        settings.setEnabled(true)
        var preparationCount = 0
        let service = ICloudUsageAggregationService(
            settings: settings,
            repository: repository,
            prepareLocalSummary: { candidate in
                preparationCount += 1
                XCTAssertNil(candidate)
                return .completed(self.summary())
            }
        )

        await service.sync(localSummary: nil, quotaSnapshots: [])

        let callCount = await repository.callCount
        XCTAssertEqual(preparationCount, 1)
        XCTAssertEqual(callCount, 1)
    }

    @MainActor
    func testSummaryWithoutDailyRowsRequiresCompletedPreparation() async {
        let repository = RepositorySpy()
        let settings = ICloudUsageSettingsStore(userDefaults: isolatedDefaults())
        settings.setEnabled(true)
        let missingDailyCoverage = summary(dailyUsage: [])
        var preparationCount = 0
        let service = ICloudUsageAggregationService(
            settings: settings,
            repository: repository,
            prepareLocalSummary: { candidate in
                preparationCount += 1
                XCTAssertEqual(candidate?.dailyUsage.isEmpty, true)
                return .completed(self.summary())
            }
        )

        await service.sync(localSummary: missingDailyCoverage, quotaSnapshots: [])

        let callCount = await repository.callCount
        XCTAssertEqual(preparationCount, 1)
        XCTAssertEqual(callCount, 1)
    }

    @MainActor
    func testFailedPreparationMakesZeroRepositoryCalls() async {
        await assertPreparationDoesNotPublish(.failed)
    }

    @MainActor
    func testSkippedPreparationMakesZeroRepositoryCalls() async {
        await assertPreparationDoesNotPublish(.skipped)
    }

    @MainActor
    func testPartialPreparationMakesZeroRepositoryCalls() async {
        await assertPreparationDoesNotPublish(.partial)
    }

    @MainActor
    func testPartialPreparationCannotPublishOnLaterLifecycleSync() async {
        let repository = RepositorySpy()
        let settings = ICloudUsageSettingsStore(userDefaults: isolatedDefaults())
        settings.setEnabled(true)
        let tracker = CostTracker(demoMode: true)
        let partialSummary = summary()
        var preparationCount = 0
        let service = ICloudUsageAggregationService(
            settings: settings,
            repository: repository,
            prepareLocalSummary: { _ in
                preparationCount += 1
                if preparationCount == 1 {
                    tracker.apply(
                        CostSummaryBuilder.CostSummaryScan(
                            summary: partialSummary,
                            deferredProviders: [.claude]
                        )
                    )
                }
                return .partial
            }
        )

        await service.sync(localSummary: nil, quotaSnapshots: [])
        await service.sync(localSummary: tracker.costSummary, quotaSnapshots: [])

        let callCount = await repository.callCount
        XCTAssertEqual(preparationCount, 2)
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(tracker.costSummary?.totalTokens, partialSummary.totalTokens)
    }

    @MainActor
    func testCompletedEmptyScanDoesNotPrepareAgainOnLaterLifecycleSync() async {
        let repository = RepositorySpy()
        let settings = ICloudUsageSettingsStore(userDefaults: isolatedDefaults())
        settings.setEnabled(true)
        let tracker = CostTracker(demoMode: true)
        let emptySummary = CostSummary(
            costs: [],
            totalCostUSD: 0,
            totalTokens: 0,
            periodDays: 30,
            dailyUsage: []
        )
        var preparationCount = 0
        let service = ICloudUsageAggregationService(
            settings: settings,
            repository: repository,
            prepareLocalSummary: { _ in
                preparationCount += 1
                tracker.apply(CostSummaryBuilder.CostSummaryScan(summary: emptySummary))
                guard let prepared = tracker.costSummary else { return .failed }
                return .completed(prepared)
            }
        )

        await service.sync(localSummary: nil, quotaSnapshots: [])
        await service.sync(localSummary: tracker.costSummary, quotaSnapshots: [])

        let callCount = await repository.callCount
        let published = await repository.synchronizedRollups
        XCTAssertEqual(preparationCount, 1)
        XCTAssertEqual(callCount, 2)
        XCTAssertTrue(published.isEmpty)
    }

    @MainActor
    func testDisablingDuringSuspendedPreparationMakesZeroRepositoryCalls() async {
        let repository = RepositorySpy()
        let settings = ICloudUsageSettingsStore(userDefaults: isolatedDefaults())
        settings.setEnabled(true)
        let preparationStarted = expectation(description: "preparation suspended")
        let gate = SuspendedPreparationGate()
        let service = ICloudUsageAggregationService(
            settings: settings,
            repository: repository,
            prepareLocalSummary: { _ in
                preparationStarted.fulfill()
                await gate.wait()
                return .completed(self.summary())
            }
        )

        let syncTask = Task {
            await service.sync(localSummary: nil, quotaSnapshots: [])
        }
        await fulfillment(of: [preparationStarted], timeout: 1)
        settings.setEnabled(false)
        await gate.resume()
        await syncTask.value

        let callCount = await repository.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testContributorsRespectSelectedWindowAndExcludeZeroRows() throws {
        let calendar = Calendar(identifier: .gregorian)
        let oldDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -8, to: day))
        let recent = rollup(firstDeviceID, input: 10)
        let old = rollup(secondDeviceID, day: oldDay, input: 20)
        let zero = rollup(secondDeviceID)
        let aggregate = ICloudUsageAggregation.fold(
            devices: [device(firstDeviceID, name: "Studio"), device(secondDeviceID, name: "Laptop")],
            rollups: [recent, old, zero],
            now: now,
            calendar: calendar
        )
        let weekStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -6, to: day))

        let contributors = aggregate.contributingDevices(
            for: .codexCli,
            startingAt: weekStart,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(contributors.map(\.id), [firstDeviceID])
    }

    func testCloudKitResultCollectorPropagatesPerRecordFailure() {
        let results: [String: Result<Int, Error>] = [
            "good": .success(1),
            "bad": .failure(TestError.unavailable),
        ]

        XCTAssertThrowsError(try CloudKitResultCollector.values(from: results))
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

    func testSameAccountQuotaUsesStableTieBreakForEqualTimestamps() throws {
        let lower = quota(account: "acct-shared", used: 12, capturedAt: now)
        let higher = quota(account: "acct-shared", used: 90, capturedAt: now)

        let forward = ICloudUsageAggregation.fold(
            devices: [device(firstDeviceID), device(secondDeviceID)],
            rollups: [
                rollup(firstDeviceID, quota: [lower]),
                rollup(secondDeviceID, quota: [higher]),
            ],
            now: now
        )
        let reverse = ICloudUsageAggregation.fold(
            devices: [device(firstDeviceID), device(secondDeviceID)],
            rollups: [
                rollup(secondDeviceID, quota: [higher]),
                rollup(firstDeviceID, quota: [lower]),
            ],
            now: now
        )

        XCTAssertEqual(try XCTUnwrap(forward.quotaSnapshots.first).windows.first?.used, 90)
        XCTAssertEqual(try XCTUnwrap(reverse.quotaSnapshots.first).windows.first?.used, 90)
    }

    func testDifferentLocalProfileIDsWithSameExternalIdentityDeduplicateQuota() throws {
        let first = providerSnapshot(
            accountID: UUID(),
            used: 90,
            capturedAt: now.addingTimeInterval(-60)
        )
        let second = providerSnapshot(accountID: UUID(), used: 12, capturedAt: now)
        let old = try XCTUnwrap(ICloudQuotaSnapshot(
            snapshot: first,
            externalAccountIdentity: "account-123"
        ))
        let latest = try XCTUnwrap(ICloudQuotaSnapshot(
            snapshot: second,
            externalAccountIdentity: "account-123"
        ))

        let result = ICloudUsageAggregation.fold(
            devices: [device(firstDeviceID), device(secondDeviceID)],
            rollups: [
                rollup(firstDeviceID, quota: [old]),
                rollup(secondDeviceID, quota: [latest]),
            ],
            now: now
        )

        XCTAssertEqual(result.quotaSnapshots.count, 1)
        XCTAssertEqual(result.quotaSnapshots.first?.windows.first?.used, 12)
        XCTAssertEqual(old.accountIdentity, latest.accountIdentity)
        XCTAssertTrue(old.accountIdentity.hasPrefix("v1:"))
        XCTAssertEqual(old.accountIdentity.count, 67)
        XCTAssertFalse(old.accountIdentity.contains("account-123"))
    }

    func testQuotaPseudonymIsProviderScoped() throws {
        let codex = try XCTUnwrap(ICloudQuotaSnapshot(
            snapshot: providerSnapshot(accountID: UUID(), used: 12, capturedAt: now),
            externalAccountIdentity: "shared-provider-id"
        ))
        let claude = try XCTUnwrap(ICloudQuotaSnapshot(
            snapshot: providerSnapshot(
                accountID: UUID(),
                used: 12,
                capturedAt: now,
                provider: .claudeCode
            ),
            externalAccountIdentity: "shared-provider-id"
        ))

        XCTAssertNotEqual(codex.accountIdentity, claude.accountIdentity)
    }

    func testQuotaSnapshotWithoutExternalIdentityIsNotPublishable() {
        let snapshot = providerSnapshot(accountID: UUID(), used: 12, capturedAt: now)

        XCTAssertNil(ICloudQuotaSnapshot(snapshot: snapshot, externalAccountIdentity: nil))
    }

    @MainActor
    func testAppLifecycleCoordinatorPublishesWithoutDashboardOpening() async {
        let refreshes = PassthroughSubject<Void, Never>()
        let costs = PassthroughSubject<Void, Never>()
        let settings = ICloudUsageSettingsStore(userDefaults: isolatedDefaults())
        settings.setEnabled(true)
        let published = expectation(description: "app lifecycle published")
        let calls = MainActorCallCounter()
        let coordinator = ICloudUsageAggregationCoordinator(
            settings: settings,
            refreshPublisher: refreshes.eraseToAnyPublisher(),
            costPublisher: costs.eraseToAnyPublisher(),
            minimumInterval: 900,
            sync: { _ in
                calls.count += 1
                published.fulfill()
            }
        )

        coordinator.activate()
        await fulfillment(of: [published], timeout: 1)

        XCTAssertEqual(calls.count, 1)
    }

    @MainActor
    func testDisabledAppLifecycleMakesZeroSyncCalls() async {
        let refreshes = PassthroughSubject<Void, Never>()
        let costs = PassthroughSubject<Void, Never>()
        let settings = ICloudUsageSettingsStore(userDefaults: isolatedDefaults())
        let calls = MainActorCallCounter()
        let coordinator = ICloudUsageAggregationCoordinator(
            settings: settings,
            refreshPublisher: refreshes.eraseToAnyPublisher(),
            costPublisher: costs.eraseToAnyPublisher(),
            minimumInterval: 0,
            sync: { _ in calls.count += 1 }
        )

        coordinator.activate()
        refreshes.send(())
        costs.send(())
        await Task.yield()

        XCTAssertEqual(calls.count, 0)
    }

    @MainActor
    func testAppLifecycleCoalescesRefreshAndCostSignalsToCoarseCadence() async {
        let refreshes = PassthroughSubject<Void, Never>()
        let costs = PassthroughSubject<Void, Never>()
        let settings = ICloudUsageSettingsStore(userDefaults: isolatedDefaults())
        settings.setEnabled(true)
        let clock = MainActorClock(now: now)
        let calls = MainActorCallCounter()
        let first = expectation(description: "initial lifecycle sync")
        let second = expectation(description: "next coarse lifecycle sync")
        let coordinator = ICloudUsageAggregationCoordinator(
            settings: settings,
            refreshPublisher: refreshes.eraseToAnyPublisher(),
            costPublisher: costs.eraseToAnyPublisher(),
            minimumInterval: 900,
            now: { clock.now },
            sync: { _ in
                calls.count += 1
                if calls.count == 1 { first.fulfill() }
                if calls.count == 2 { second.fulfill() }
            }
        )

        coordinator.activate()
        await fulfillment(of: [first], timeout: 1)
        await Task.yield()
        refreshes.send(())
        costs.send(())
        await Task.yield()
        XCTAssertEqual(calls.count, 1)

        clock.now = now.addingTimeInterval(901)
        refreshes.send(())
        await fulfillment(of: [second], timeout: 1)
        XCTAssertEqual(calls.count, 2)
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
        let source = rollup(firstDeviceID, input: 42, cost: 1.5)
        let payload = try ICloudUsageRecordSchema.fields(for: source)

        XCTAssertEqual(Set(payload.keys), ICloudUsageRecordSchema.rollupFieldNames)
        XCTAssertEqual(payload["cacheCreationTokens"] as? Int, 0)
        let encodedDay = try XCTUnwrap(payload["day"] as? String)
        XCTAssertEqual(ICloudUsageRecordSchema.date(fromDayString: encodedDay), source.day)
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

    func testCloudKitPayloadDoesNotContainRawProviderAccountIdentity() throws {
        let rawIdentity = "provider-account-secret-123"
        let snapshot = try XCTUnwrap(ICloudQuotaSnapshot(
            snapshot: providerSnapshot(accountID: UUID(), used: 12, capturedAt: now),
            externalAccountIdentity: rawIdentity
        ))
        let payload = try ICloudUsageRecordSchema.fields(
            for: rollup(firstDeviceID, quota: [snapshot])
        )
        let quotaData = try XCTUnwrap(payload["quotaSnapshots"] as? Data)
        let serialized = try XCTUnwrap(String(data: quotaData, encoding: .utf8))

        XCTAssertFalse(serialized.contains(rawIdentity))
        XCTAssertTrue(serialized.contains(snapshot.accountIdentity))
    }

    func testFeatureOffMakesZeroRepositoryCalls() async {
        let repository = RepositorySpy()
        let settings = ICloudUsageSettingsStore(userDefaults: isolatedDefaults())
        let identityReads = MainActorCallCounter()
        let service = ICloudUsageAggregationService(
            settings: settings,
            repository: repository,
            quotaSnapshots: {
                identityReads.count += 1
                return []
            }
        )

        await service.sync(localSummary: summary())

        let callCount = await repository.callCount
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(identityReads.count, 0)
        XCTAssertNil(service.aggregate)
    }

    func testEveryProductionSyncPublishesCurrentQuotaSnapshots() async {
        let repository = RepositorySpy()
        let settings = ICloudUsageSettingsStore(userDefaults: isolatedDefaults())
        settings.setEnabled(true)
        let identityReads = MainActorCallCounter()
        let currentQuota = quota(account: "pseudonym", used: 12, capturedAt: now)
        let service = ICloudUsageAggregationService(
            settings: settings,
            repository: repository,
            quotaSnapshots: {
                identityReads.count += 1
                return [currentQuota]
            }
        )

        await service.sync(localSummary: summary())
        await service.sync(localSummary: summary())

        let published = await repository.synchronizedRollups
        let callCount = await repository.callCount
        XCTAssertEqual(identityReads.count, 2)
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(published.flatMap(\.quotaSnapshots), [currentQuota])
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

    private func providerSnapshot(
        accountID: UUID,
        used: Double,
        capturedAt: Date,
        provider: ServiceType = .codexCli
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            id: "\(provider.rawValue)-\(accountID.uuidString)",
            title: provider.displayName,
            service: provider,
            updatedAt: capturedAt,
            limits: [
                SnapshotLimit(
                    id: "weekly",
                    kind: .weekly,
                    title: "Weekly",
                    usageLimit: UsageLimit(used: used, total: 100, resetTime: nil)
                )
            ],
            emptyDetail: "",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: accountID
        )
    }

    private func rollup(
        _ deviceID: UUID,
        day: Date? = nil,
        input: Int = 0,
        output: Int = 0,
        cost: Double = 0,
        quota: [ICloudQuotaSnapshot] = [],
        updatedAt: Date? = nil
    ) -> ICloudDailyUsageRollup {
        ICloudDailyUsageRollup(
            deviceID: deviceID,
            provider: .codexCli,
            day: day ?? self.day,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: 0,
            estimatedCostUSD: cost,
            quotaSnapshots: quota,
            updatedAt: updatedAt ?? now
        )
    }

    private func summary(dailyUsage: [DailyTokenUsage]? = nil) -> CostSummary {
        CostSummary(
            costs: [],
            totalCostUSD: 1,
            totalTokens: 42,
            periodDays: 30,
            dailyUsage: dailyUsage ?? [
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

    private func legacyDailyUsage() throws -> DailyTokenUsage {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        return try decoder.decode(
            DailyTokenUsage.self,
            from: encoder.encode(
                LegacyDailyUsageWire(
                    date: day,
                    provider: .codexCli,
                    inputTokens: 42,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 1
                )
            )
        )
    }

    @MainActor
    private func assertPreparationDoesNotPublish(
        _ result: ICloudUsageSummaryPreparationResult
    ) async {
        let repository = RepositorySpy()
        let settings = ICloudUsageSettingsStore(userDefaults: isolatedDefaults())
        settings.setEnabled(true)
        let service = ICloudUsageAggregationService(
            settings: settings,
            repository: repository,
            prepareLocalSummary: { _ in result }
        )

        await service.sync(localSummary: nil, quotaSnapshots: [])

        let callCount = await repository.callCount
        XCTAssertEqual(callCount, 0)
    }

    private enum TestError: Error { case unavailable }
}

@MainActor
private final class MainActorCallCounter {
    var count = 0
}

@MainActor
private final class MainActorClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private actor RepositorySpy: ICloudUsageRepository {
    private(set) var callCount = 0
    private(set) var synchronizedRollups: [ICloudDailyUsageRollup] = []
    let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func synchronize(device: ICloudUsageDevice, rollups: [ICloudDailyUsageRollup]) async throws
        -> ICloudUsageRepositorySnapshot {
        callCount += 1
        synchronizedRollups = rollups
        if let error { throw error }
        return ICloudUsageRepositorySnapshot(devices: [device], rollups: rollups)
    }

    func removeDevice(id: UUID) async throws {
        callCount += 1
        if let error { throw error }
    }
}

private struct LegacyDailyUsageWire: Encodable {
    let date: Date
    let provider: ServiceType
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let estimatedCostUSD: Double
}

private actor SuspendedPreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
