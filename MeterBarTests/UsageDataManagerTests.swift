import Combine
import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Orchestration coverage for `UsageDataManager.refreshAll` / `refresh(service:)`
/// — merge, graceful degradation on fetch failure, disabled-provider handling —
/// driven through the provider seam so no network or local credentials are
/// touched. Most scenarios hide Claude Code; focused coverage injects its
/// account-aware provider seam directly.
@MainActor
final class UsageDataManagerTests: XCTestCase {
    private final class StubClaudeProvider: ClaudeCodeUsageProviding {
        var hasAccess: Bool
        var result: Result<UsageMetrics, Error>
        private(set) var fetchCount = 0

        init(hasAccess: Bool, result: Result<UsageMetrics, Error>) {
            self.hasAccess = hasAccess
            self.result = result
        }

        func fetchUsageMetrics(account: ClaudeCodeAccount) async throws -> UsageMetrics {
            fetchCount += 1
            return try result.get()
        }
    }

    /// Stub provider whose access flag and fetch result are fully controlled.
    private final class StubProvider: SimpleUsageProviding, CodexUsageProviding {
        var hasAccess: Bool
        var result: Result<UsageMetrics, Error>
        var suspendsFetch = false
        private(set) var fetchCount = 0
        private var fetchContinuation: CheckedContinuation<Void, Never>?

        init(hasAccess: Bool, result: Result<UsageMetrics, Error>) {
            self.hasAccess = hasAccess
            self.result = result
        }

        func fetchUsageMetrics() async throws -> UsageMetrics {
            fetchCount += 1
            if suspendsFetch {
                await withCheckedContinuation { continuation in
                    fetchContinuation = continuation
                }
            }
            return try result.get()
        }

        func canAccess(account: CodexAccount) async -> Bool { hasAccess }
        func fetchUsageMetrics(account: CodexAccount) async throws -> UsageMetrics {
            try await fetchUsageMetrics()
        }

        func resumeFetch() {
            suspendsFetch = false
            fetchContinuation?.resume()
            fetchContinuation = nil
        }
    }

    private enum StubError: Error { case fetchFailed }

    private final class MultiAccountCodexProvider: CodexUsageProviding {
        var metricsByAccount: [UUID: UsageMetrics]
        var failingAccountIDs: Set<UUID> = []

        init(metricsByAccount: [UUID: UsageMetrics]) {
            self.metricsByAccount = metricsByAccount
        }

        func canAccess(account: CodexAccount) async -> Bool {
            metricsByAccount[account.id] != nil
        }

        func fetchUsageMetrics(account: CodexAccount) async throws -> UsageMetrics {
            if failingAccountIDs.contains(account.id) { throw StubError.fetchFailed }
            guard let metrics = metricsByAccount[account.id] else { throw StubError.fetchFailed }
            return metrics
        }
    }

    private var tempDirectory: URL!
    private var createdSuiteNames: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageDataManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        // Drop the UUID-scoped suites so repeated runs don't accumulate
        // plist-backed preference domains (same convention as the other
        // suite-based tests, e.g. NotificationPreferencesStoreTests).
        for suite in createdSuiteNames {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        createdSuiteNames = []
        tempDirectory = nil
        try super.tearDownWithError()
    }

    /// Builds a manager with isolated stores. `hidden` always includes
    /// `.claudeCode`; `preload` seeds the on-disk cache before construction so
    /// graceful-degradation paths have something to preserve.
    private func makeManager(
        codex: CodexUsageProviding,
        cursor: StubProvider,
        claude: ClaudeCodeUsageProviding? = nil,
        claudeCodeAccountStore: ClaudeCodeAccountStore? = nil,
        codexAccountStore: CodexAccountStore? = nil,
        hidden: Set<ServiceType> = [],
        preload: [ServiceType: UsageMetrics] = [:],
        preloadClaudeAccountMetrics: [UUID: UsageMetrics] = [:],
        savedRefreshInterval: RefreshInterval? = nil,
        parseHealthStore: ProviderParseHealthStore? = nil,
        schedulesAutoRefresh: Bool = false
    ) -> (manager: UsageDataManager, sharedStore: SharedDataStore) {
        let suiteName = "UsageDataManagerTests-\(UUID().uuidString)"
        createdSuiteNames.append(contentsOf: [suiteName, "\(suiteName)-vis"])
        guard let cacheDefaults = UserDefaults(suiteName: suiteName),
              let visibilityDefaults = UserDefaults(suiteName: "\(suiteName)-vis") else {
            preconditionFailure("Unable to create isolated test defaults")
        }
        if !preload.isEmpty, let data = MetricsCodec.encode(preload) {
            cacheDefaults.set(data, forKey: StorageKeys.cachedUsageMetrics)
        }
        if !preloadClaudeAccountMetrics.isEmpty,
           let data = try? JSONEncoder().encode(preloadClaudeAccountMetrics) {
            cacheDefaults.set(data, forKey: StorageKeys.cachedClaudeCodeAccountMetrics)
        }
        if let savedRefreshInterval {
            cacheDefaults.set(savedRefreshInterval.rawValue, forKey: StorageKeys.refreshInterval)
        }

        let visibility = ProviderVisibilityStore(userDefaults: visibilityDefaults)
        let hiddenProviders = claude == nil ? hidden.union([.claudeCode]) : hidden
        for service in hiddenProviders {
            visibility.set(service, isEnabled: false)
        }

        let sharedStore = SharedDataStore(directoryOverride: tempDirectory) {}

        let manager = UsageDataManager(
            codexCliService: codex,
            cursorService: cursor,
            claudeCodeService: claude ?? ClaudeCodeLocalService.shared,
            claudeCodeAccountStore: claudeCodeAccountStore,
            codexAccountStore: codexAccountStore,
            providerVisibilityStore: visibility,
            sharedStore: sharedStore,
            preferences: cacheDefaults,
            cacheDefaults: cacheDefaults,
            parseHealthStore: parseHealthStore,
            schedulesAutoRefresh: schedulesAutoRefresh
        )
        return (manager, sharedStore)
    }

    func testRefreshRecordsSuccessAndFailureHealth() async {
        let healthSuite = "UsageDataManagerHealthTests-\(UUID().uuidString)"
        createdSuiteNames.append(healthSuite)
        guard let healthDefaults = UserDefaults(suiteName: healthSuite) else {
            return XCTFail("Unable to create isolated health defaults")
        }
        let health = ProviderParseHealthStore(userDefaults: healthDefaults)
        let codex = StubProvider(hasAccess: true, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: true, result: .failure(ServiceError.parsingError))
        let (manager, _) = makeManager(codex: codex, cursor: cursor, parseHealthStore: health)

        await manager.refreshAll()

        XCTAssertEqual(health.records[.codexCli]?.consecutiveFailures, 0)
        XCTAssertEqual(health.records[.cursor]?.consecutiveFailures, 1)
        XCTAssertTrue(health.records[.cursor]?.lastFailureWasShapeMismatch ?? false)
    }

    func testRefreshAllMergesBothEnabledProviders() async {
        let codex = StubProvider(hasAccess: true, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: true, result: .success(MetricsFixtures.cursor()))
        let (manager, sharedStore) = makeManager(codex: codex, cursor: cursor)

        await manager.refreshAll()

        XCTAssertEqual(Set(manager.metrics.keys), [.codexCli, .cursor])
        XCTAssertEqual(manager.metrics[.codexCli]?.resetCreditsAvailable, 2)
        XCTAssertFalse(manager.isLoading)

        // The merged snapshot is mirrored to the App Group file for the widget.
        sharedStore.flushPendingWrites()
        XCTAssertEqual(Set(sharedStore.loadMetrics().keys), [.codexCli, .cursor])
    }

    func testRefreshAllRetriesEnabledClaudeWhenPublishedAccessIsFalse() async throws {
        let accountSuite = "UsageDataManagerTests-claude-accounts-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = ClaudeCodeAccountStore(userDefaults: accountDefaults)
        let refreshed = MetricsFixtures.claudeCode(sessionUsedPercent: 7)
        let claude = StubClaudeProvider(hasAccess: false, result: .success(refreshed))
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, sharedStore) = makeManager(
            codex: codex,
            cursor: cursor,
            claude: claude,
            claudeCodeAccountStore: accountStore,
            hidden: [.codexCli, .cursor, .openRouter, .grok]
        )

        await manager.refreshAll()

        XCTAssertEqual(claude.fetchCount, 1)
        XCTAssertEqual(manager.metrics[.claudeCode]?.sessionLimit?.used, 7)
        sharedStore.flushPendingWrites()
        XCTAssertEqual(sharedStore.loadMetrics()[.claudeCode]?.sessionLimit?.used, 7)
    }

    func testRefreshAllBridgesEveryEnabledClaudeAccountToWidgetData() async throws {
        let accountSuite = "UsageDataManagerTests-claude-widget-accounts-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = ClaudeCodeAccountStore(userDefaults: accountDefaults)
        accountStore.addAccount(name: "Work", configDirectory: "/tmp/claude-work")
        let work = try XCTUnwrap(accountStore.customAccounts.first)
        let refreshed = MetricsFixtures.claudeCode(sessionUsedPercent: 17)
        let claude = StubClaudeProvider(hasAccess: true, result: .success(refreshed))
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, sharedStore) = makeManager(
            codex: codex,
            cursor: cursor,
            claude: claude,
            claudeCodeAccountStore: accountStore,
            hidden: [.codexCli, .cursor, .openRouter, .grok]
        )

        await manager.refreshAll()

        XCTAssertEqual(Set(manager.claudeCodeAccountMetrics.keys), [ClaudeCodeAccount.defaultID, work.id])
        sharedStore.flushPendingWrites()
        XCTAssertEqual(
            sharedStore.loadAccountMetrics().map(\.id),
            [ClaudeCodeAccount.defaultID, work.id]
        )
        XCTAssertEqual(
            sharedStore.loadAccountMetrics().map(\.name),
            [ClaudeCodeAccount.defaultName, "Work"]
        )
    }

    func testRefreshAllRestoresClaudeAccountCacheAfterRelaunchAndTransientFailure() async throws {
        let accountSuite = "UsageDataManagerTests-claude-cache-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = ClaudeCodeAccountStore(userDefaults: accountDefaults)
        let cached = MetricsFixtures.claudeCode(sessionUsedPercent: 23)
        let claude = StubClaudeProvider(hasAccess: true, result: .failure(StubError.fetchFailed))
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, sharedStore) = makeManager(
            codex: codex,
            cursor: cursor,
            claude: claude,
            claudeCodeAccountStore: accountStore,
            hidden: [.codexCli, .cursor, .openRouter, .grok],
            preloadClaudeAccountMetrics: [ClaudeCodeAccount.defaultID: cached]
        )

        await manager.refreshAll()

        XCTAssertEqual(
            manager.claudeCodeAccountMetrics[ClaudeCodeAccount.defaultID]?.sessionLimit?.used,
            23
        )
        sharedStore.flushPendingWrites()
        XCTAssertEqual(
            sharedStore.loadAccountMetrics().first?.metrics.sessionLimit?.used,
            23
        )
    }

    func testChangingRefreshIntervalPublishesToObservers() {
        let codex = StubProvider(hasAccess: true, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: true, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(codex: codex, cursor: cursor)
        var publicationCount = 0
        let cancellable = manager.objectWillChange.sink { publicationCount += 1 }
        let newInterval: RefreshInterval = manager.refreshInterval == .fiveMinutes ? .manual : .fiveMinutes

        manager.refreshInterval = newInterval

        XCTAssertEqual(publicationCount, 1)
        withExtendedLifetime(cancellable) {}
    }

    func testMissingRefreshPreferenceDefaultsToTenMinutes() {
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(codex: codex, cursor: cursor)

        XCTAssertEqual(manager.refreshInterval, .tenMinutes)
    }

    func testExistingRefreshPreferencesArePreserved() {
        let existingChoices: [RefreshInterval] = [
            .oneMinute,
            .twoMinutes,
            .fiveMinutes,
            .fifteenMinutes,
            .thirtyMinutes,
            .manual
        ]

        for existingChoice in existingChoices {
            let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
            let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
            let (manager, _) = makeManager(
                codex: codex,
                cursor: cursor,
                savedRefreshInterval: existingChoice
            )

            XCTAssertEqual(manager.refreshInterval, existingChoice)
        }
    }

    func testDefaultBackgroundSchedulerUsesTenMinuteCadence() throws {
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            schedulesAutoRefresh: true
        )

        XCTAssertEqual(try XCTUnwrap(manager.scheduledRefreshInterval), 600, accuracy: 0.01)

        manager.refreshInterval = .manual
        XCTAssertNil(manager.scheduledRefreshInterval)
    }

    func testRefreshAllSkipsOverlappingCycle() async {
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: true, result: .success(MetricsFixtures.cursor()))
        cursor.suspendsFetch = true
        let (manager, _) = makeManager(codex: codex, cursor: cursor)

        let firstRefresh = Task { await manager.refreshAll() }
        for _ in 0..<100 where cursor.fetchCount == 0 {
            await Task.yield()
        }
        guard cursor.fetchCount == 1, manager.isLoading else {
            cursor.resumeFetch()
            await firstRefresh.value
            return XCTFail("the first refresh should be suspended inside the provider fetch")
        }

        await manager.refreshAll()

        XCTAssertEqual(cursor.fetchCount, 1)
        cursor.resumeFetch()
        await firstRefresh.value
        XCTAssertFalse(manager.isLoading)
    }

    func testWakeRefreshesWhenEnabledCachedDataIsTenMinutesOld() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let staleMetrics = UsageMetrics(
            service: .cursor,
            weeklyLimit: UsageLimit(used: 1, total: 10, resetTime: now),
            lastUpdated: now.addingTimeInterval(-RefreshInterval.tenMinutes.seconds)
        )
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: true, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            hidden: [.codexCli],
            preload: [.cursor: staleMetrics]
        )

        await manager.refreshAfterWakeIfNeeded(now: now)

        XCTAssertEqual(cursor.fetchCount, 1)
    }

    func testWakeDoesNotRefreshFreshOrManualOnlyData() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let freshMetrics = UsageMetrics(
            service: .cursor,
            weeklyLimit: UsageLimit(used: 1, total: 10, resetTime: now),
            lastUpdated: now.addingTimeInterval(-RefreshInterval.tenMinutes.seconds + 1)
        )
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: true, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            hidden: [.codexCli],
            preload: [.cursor: freshMetrics]
        )

        await manager.refreshAfterWakeIfNeeded(now: now)
        XCTAssertEqual(cursor.fetchCount, 0)

        manager.metrics[.cursor] = UsageMetrics(
            service: .cursor,
            weeklyLimit: freshMetrics.weeklyLimit,
            lastUpdated: now.addingTimeInterval(-RefreshInterval.tenMinutes.seconds)
        )
        manager.refreshInterval = .manual
        await manager.refreshAfterWakeIfNeeded(now: now)

        XCTAssertEqual(cursor.fetchCount, 0)
    }

    func testWakeIgnoresMissingMetricsForInaccessibleCodexAccounts() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let freshMetrics = UsageMetrics(
            service: .cursor,
            weeklyLimit: UsageLimit(used: 1, total: 10, resetTime: now),
            lastUpdated: now
        )
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: true, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            preload: [.cursor: freshMetrics]
        )

        await manager.refreshAfterWakeIfNeeded(now: now)

        XCTAssertEqual(cursor.fetchCount, 0)
    }

    func testRefreshAllPreservesCachedMetricsWhenProviderFails() async {
        // Cursor previously cached a distinctive value; this refresh it throws.
        let cachedCursor = MetricsFixtures.cursor(planUsed: 999)
        let codex = StubProvider(hasAccess: true, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: true, result: .failure(StubError.fetchFailed))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            preload: [.codexCli: MetricsFixtures.codexCli(), .cursor: cachedCursor]
        )

        await manager.refreshAll()

        // Codex refreshed; Cursor degraded gracefully to its cached value.
        XCTAssertEqual(Set(manager.metrics.keys), [.codexCli, .cursor])
        XCTAssertEqual(manager.metrics[.cursor]?.weeklyLimit?.used, 999)
        XCTAssertNotNil(manager.lastError)
    }

    func testRefreshAllSkipsDisabledProvider() async {
        let codex = StubProvider(hasAccess: true, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: true, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(codex: codex, cursor: cursor, hidden: [.cursor])

        await manager.refreshAll()

        XCTAssertEqual(Set(manager.metrics.keys), [.codexCli])
        XCTAssertEqual(cursor.fetchCount, 0, "disabled provider must not be fetched")
    }

    func testRefreshAllSkipsProviderWithoutAccess() async {
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: true, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(codex: codex, cursor: cursor)

        await manager.refreshAll()

        XCTAssertEqual(codex.fetchCount, 0, "provider without access must not be fetched")
        XCTAssertEqual(Set(manager.metrics.keys), [.cursor])
    }

    func testRefreshSingleDisabledServiceRemovesIt() async {
        let codex = StubProvider(hasAccess: true, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: true, result: .success(MetricsFixtures.cursor()))
        let (manager, sharedStore) = makeManager(
            codex: codex,
            cursor: cursor,
            hidden: [.cursor],
            preload: [.cursor: MetricsFixtures.cursor()]
        )

        // Cursor is disabled, so refreshing it should drop the cached entry.
        await manager.refresh(service: .cursor)

        XCTAssertNil(manager.metrics[.cursor])
        sharedStore.flushPendingWrites()
        XCTAssertNil(sharedStore.loadMetrics()[.cursor])
    }

    func testRefreshAllFetchesIndependentCodexAccountsAndBridgesLabels() async throws {
        let accountSuite = "UsageDataManagerTests-accounts-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = CodexAccountStore(userDefaults: accountDefaults)
        accountStore.addAccount(name: "Work", homeDirectory: "/tmp/codex-work")
        let work = try XCTUnwrap(accountStore.customAccounts.first)
        let provider = MultiAccountCodexProvider(metricsByAccount: [
            CodexAccount.defaultID: MetricsFixtures.codexCli(sessionUsedPercent: 20),
            work.id: MetricsFixtures.codexCli(sessionUsedPercent: 80)
        ])
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, sharedStore) = makeManager(
            codex: provider,
            cursor: cursor,
            codexAccountStore: accountStore
        )

        await manager.refreshAll()

        XCTAssertEqual(manager.codexAccountMetrics[CodexAccount.defaultID]?.sessionLimit?.used, 20)
        XCTAssertEqual(manager.codexAccountMetrics[work.id]?.sessionLimit?.used, 80)
        XCTAssertEqual(manager.metrics[.codexCli]?.sessionLimit?.used, 20)
        sharedStore.flushPendingWrites()
        XCTAssertEqual(sharedStore.loadAccountMetrics().map(\.name), [CodexAccount.defaultName, "Work"])
    }

    func testRefreshAllExcludesDisabledCodexAccountsFromMetricsAndWidgetData() async throws {
        let accountSuite = "UsageDataManagerTests-disabled-accounts-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = CodexAccountStore(userDefaults: accountDefaults)
        accountStore.addAccount(name: "Work", homeDirectory: "/tmp/codex-work")
        let work = try XCTUnwrap(accountStore.customAccounts.first)
        accountStore.setEnabled(false, for: work.id)
        let provider = MultiAccountCodexProvider(metricsByAccount: [
            CodexAccount.defaultID: MetricsFixtures.codexCli(sessionUsedPercent: 20),
            work.id: MetricsFixtures.codexCli(sessionUsedPercent: 80)
        ])
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, sharedStore) = makeManager(
            codex: provider,
            cursor: cursor,
            codexAccountStore: accountStore
        )

        await manager.refreshAll()

        XCTAssertEqual(Set(manager.codexAccountMetrics.keys), [CodexAccount.defaultID])
        XCTAssertEqual(manager.metrics[.codexCli]?.sessionLimit?.used, 20)
        sharedStore.flushPendingWrites()
        XCTAssertEqual(sharedStore.loadAccountMetrics().map(\.id), [CodexAccount.defaultID])
    }

    func testRefreshAllClearsStaleCodexMetricsWhenEveryAccountIsDisabled() async throws {
        let accountSuite = "UsageDataManagerTests-all-disabled-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = CodexAccountStore(userDefaults: accountDefaults)
        accountStore.setEnabled(false, for: CodexAccount.defaultID)
        let staleMetrics = MetricsFixtures.codexCli(sessionUsedPercent: 80)
        let provider = MultiAccountCodexProvider(metricsByAccount: [CodexAccount.defaultID: staleMetrics])
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, sharedStore) = makeManager(
            codex: provider,
            cursor: cursor,
            codexAccountStore: accountStore,
            preload: [.codexCli: staleMetrics]
        )

        await manager.refreshAll()

        XCTAssertNil(manager.metrics[.codexCli])
        XCTAssertTrue(manager.codexAccountMetrics.isEmpty)
        sharedStore.flushPendingWrites()
        XCTAssertNil(sharedStore.loadMetrics()[.codexCli])
        XCTAssertTrue(sharedStore.loadAccountMetrics().isEmpty)
    }

    func testRefreshAllDoesNotMoveAggregateMetricsBetweenCodexProfiles() async throws {
        let accountSuite = "UsageDataManagerTests-profile-switch-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = CodexAccountStore(userDefaults: accountDefaults)
        accountStore.addAccount(name: "Work", homeDirectory: "/tmp/codex-work")
        let work = try XCTUnwrap(accountStore.customAccounts.first)
        accountStore.setEnabled(false, for: CodexAccount.defaultID)
        let workMetrics = MetricsFixtures.codexCli(sessionUsedPercent: 80)
        let provider = MultiAccountCodexProvider(metricsByAccount: [work.id: workMetrics])
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, sharedStore) = makeManager(
            codex: provider,
            cursor: cursor,
            codexAccountStore: accountStore
        )

        await manager.refreshAll()
        XCTAssertEqual(manager.metrics[.codexCli]?.sessionLimit?.used, 80)

        accountStore.setEnabled(true, for: CodexAccount.defaultID)
        accountStore.setEnabled(false, for: work.id)
        await manager.refreshAll()

        XCTAssertNil(manager.metrics[.codexCli])
        XCTAssertTrue(manager.codexAccountMetrics.isEmpty)
        sharedStore.flushPendingWrites()
        XCTAssertNil(sharedStore.loadMetrics()[.codexCli])
        XCTAssertTrue(sharedStore.loadAccountMetrics().isEmpty)
    }

    func testRefreshAllClearsCachedCodexMetricsWhenAccountLosesAccess() async {
        let initialMetrics = MetricsFixtures.codexCli(sessionUsedPercent: 80)
        let provider = MultiAccountCodexProvider(metricsByAccount: [CodexAccount.defaultID: initialMetrics])
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, sharedStore) = makeManager(codex: provider, cursor: cursor)

        await manager.refreshAll()
        XCTAssertEqual(manager.codexAccountMetrics[CodexAccount.defaultID]?.sessionLimit?.used, 80)

        provider.metricsByAccount = [:]
        await manager.refreshAll()

        XCTAssertNil(manager.metrics[.codexCli])
        XCTAssertTrue(manager.codexAccountMetrics.isEmpty)
        sharedStore.flushPendingWrites()
        XCTAssertNil(sharedStore.loadMetrics()[.codexCli])
        XCTAssertTrue(sharedStore.loadAccountMetrics().isEmpty)
    }

    func testRefreshAllKeepsTransientCodexFailureCacheScopedToItsAccount() async throws {
        let accountSuite = "UsageDataManagerTests-transient-failure-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = CodexAccountStore(userDefaults: accountDefaults)
        accountStore.addAccount(name: "Work", homeDirectory: "/tmp/codex-work")
        let work = try XCTUnwrap(accountStore.customAccounts.first)
        let provider = MultiAccountCodexProvider(metricsByAccount: [
            CodexAccount.defaultID: MetricsFixtures.codexCli(sessionUsedPercent: 20),
            work.id: MetricsFixtures.codexCli(sessionUsedPercent: 80)
        ])
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: provider,
            cursor: cursor,
            codexAccountStore: accountStore
        )

        await manager.refreshAll()
        provider.failingAccountIDs = [CodexAccount.defaultID]
        provider.metricsByAccount[work.id] = MetricsFixtures.codexCli(sessionUsedPercent: 90)
        await manager.refreshAll()

        XCTAssertEqual(manager.codexAccountMetrics[CodexAccount.defaultID]?.sessionLimit?.used, 20)
        XCTAssertEqual(manager.codexAccountMetrics[work.id]?.sessionLimit?.used, 90)
        XCTAssertEqual(manager.metrics[.codexCli]?.sessionLimit?.used, 20)
    }

    func testApplyResetCreditRefreshPublishesAccountAndSharedMetrics() {
        let codex = StubProvider(hasAccess: true, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, sharedStore) = makeManager(codex: codex, cursor: cursor)
        let refreshed = MetricsFixtures.codexCli(sessionUsedPercent: 0, resetCreditsAvailable: 0)

        manager.applyCodexResetCreditRefresh(refreshed, accountID: CodexAccount.defaultID)

        XCTAssertEqual(manager.codexAccountMetrics[CodexAccount.defaultID]?.resetCreditsAvailable, 0)
        XCTAssertEqual(manager.metrics[.codexCli]?.sessionLimit?.used, 0)
        sharedStore.flushPendingWrites()
        XCTAssertEqual(sharedStore.loadMetrics()[.codexCli]?.resetCreditsAvailable, 0)
    }
}
