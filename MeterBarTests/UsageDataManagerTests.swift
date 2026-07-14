import Combine
import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Orchestration coverage for `UsageDataManager.refreshAll` / `refresh(service:)`
/// — merge, graceful degradation on fetch failure, disabled-provider handling —
/// driven through the provider seam so no network or local credentials are
/// touched. Claude Code is hidden in every scenario (its account-aware path is
/// out of scope here), leaving Codex + Cursor as the single-account providers.
@MainActor
final class UsageDataManagerTests: XCTestCase {

    /// Stub provider whose access flag and fetch result are fully controlled.
    private final class StubProvider: SimpleUsageProviding, CodexUsageProviding {
        var hasAccess: Bool
        var result: Result<UsageMetrics, Error>
        private(set) var fetchCount = 0

        init(hasAccess: Bool, result: Result<UsageMetrics, Error>) {
            self.hasAccess = hasAccess
            self.result = result
        }

        func fetchUsageMetrics() async throws -> UsageMetrics {
            fetchCount += 1
            return try result.get()
        }

        func canAccess(account: CodexAccount) async -> Bool { hasAccess }
        func fetchUsageMetrics(account: CodexAccount) async throws -> UsageMetrics {
            try await fetchUsageMetrics()
        }
    }

    private enum StubError: Error { case fetchFailed }

    private final class MultiAccountCodexProvider: CodexUsageProviding {
        let metricsByAccount: [UUID: UsageMetrics]

        init(metricsByAccount: [UUID: UsageMetrics]) {
            self.metricsByAccount = metricsByAccount
        }

        func canAccess(account: CodexAccount) async -> Bool {
            metricsByAccount[account.id] != nil
        }

        func fetchUsageMetrics(account: CodexAccount) async throws -> UsageMetrics {
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
        codexAccountStore: CodexAccountStore? = nil,
        hidden: Set<ServiceType> = [],
        preload: [ServiceType: UsageMetrics] = [:],
        parseHealthStore: ProviderParseHealthStore? = nil
    ) -> (manager: UsageDataManager, sharedStore: SharedDataStore) {
        let suiteName = "UsageDataManagerTests-\(UUID().uuidString)"
        createdSuiteNames.append(contentsOf: [suiteName, "\(suiteName)-vis"])
        let cacheDefaults = UserDefaults(suiteName: suiteName)!
        if !preload.isEmpty, let data = MetricsCodec.encode(preload) {
            cacheDefaults.set(data, forKey: StorageKeys.cachedUsageMetrics)
        }

        let visibilityDefaults = UserDefaults(suiteName: "\(suiteName)-vis")!
        let visibility = ProviderVisibilityStore(userDefaults: visibilityDefaults)
        for service in hidden.union([.claudeCode]) {
            visibility.set(service, isEnabled: false)
        }

        let sharedStore = SharedDataStore(directoryOverride: tempDirectory) {}

        let manager = UsageDataManager(
            codexCliService: codex,
            cursorService: cursor,
            codexAccountStore: codexAccountStore,
            providerVisibilityStore: visibility,
            sharedStore: sharedStore,
            cacheDefaults: cacheDefaults,
            parseHealthStore: parseHealthStore,
            schedulesAutoRefresh: false
        )
        return (manager, sharedStore)
    }

    func testRefreshRecordsSuccessAndFailureHealth() async {
        let healthSuite = "UsageDataManagerHealthTests-\(UUID().uuidString)"
        createdSuiteNames.append(healthSuite)
        let health = ProviderParseHealthStore(userDefaults: UserDefaults(suiteName: healthSuite)!)
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

    func testChangingRefreshIntervalPublishesToObservers() {
        let savedRefreshInterval = UserDefaults.standard.object(forKey: StorageKeys.refreshInterval)
        defer {
            if let savedRefreshInterval {
                UserDefaults.standard.set(savedRefreshInterval, forKey: StorageKeys.refreshInterval)
            } else {
                UserDefaults.standard.removeObject(forKey: StorageKeys.refreshInterval)
            }
        }

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
