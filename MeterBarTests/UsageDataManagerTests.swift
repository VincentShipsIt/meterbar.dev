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
    /// Distinguishes a serial orchestration from a concurrent one without ever
    /// risking a hang: each fetch registers itself, spins on `Task.yield()` for
    /// a bounded number of turns waiting for its peers to arrive, then proceeds
    /// regardless. A serial implementation simply never sees more than one leg
    /// in flight, so `maxInFlight` stays 1.
    ///
    /// Everything here runs on the main actor alongside the manager, so plain
    /// mutable state is safe.
    @MainActor
    private final class ConcurrencyProbe {
        private(set) var maxInFlight = 0
        private var inFlight = 0
        private let expected: Int

        init(expected: Int) {
            self.expected = expected
        }

        func recordFetch() async {
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            for _ in 0..<200 where inFlight < expected {
                await Task.yield()
            }
            inFlight -= 1
        }
    }

    private final class StubClaudeProvider: ClaudeCodeUsageProviding {
        var hasAccess: Bool
        var result: Result<UsageMetrics, Error>
        var resultsByAccount: [UUID: Result<UsageMetrics, Error>] = [:]
        var accountAuthStates: [UUID: ClaudeCodeAuthState] = [:]
        var probe: ConcurrencyProbe?
        private(set) var fetchCount = 0
        private(set) var refreshTriggers: [ClaudeTokenRefreshTrigger] = []

        init(hasAccess: Bool, result: Result<UsageMetrics, Error>) {
            self.hasAccess = hasAccess
            self.result = result
        }

        func fetchUsageMetrics(account: ClaudeCodeAccount) async throws -> UsageMetrics {
            try await fetchUsageMetrics(account: account, trigger: .background)
        }

        func fetchUsageMetrics(
            account: ClaudeCodeAccount,
            trigger: ClaudeTokenRefreshTrigger
        ) async throws -> UsageMetrics {
            fetchCount += 1
            refreshTriggers.append(trigger)
            await probe?.recordFetch()
            return try (resultsByAccount[account.id] ?? result).get()
        }
    }

    private final class StubFableTracker: ClaudeFableSessionTracking {
        private(set) var refreshedAccountIDs: [[UUID]] = []

        func scheduleRefresh(accounts: [ClaudeCodeAccount]) {
            refreshedAccountIDs.append(accounts.map(\.id))
        }
    }

    /// Stub provider whose access flag and fetch result are fully controlled.
    private final class StubProvider: SimpleUsageProviding, CodexUsageProviding {
        var hasAccess: Bool
        var result: Result<UsageMetrics, Error>
        var suspendsFetch = false
        var probe: ConcurrencyProbe?
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
            await probe?.recordFetch()
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

    /// Carries a phase label so a test can assert *which* leg's failure ended up
    /// in `lastError`, rather than merely that some failure did.
    private struct TaggedError: Error { let tag: String }

    private final class MultiAccountCodexProvider: CodexUsageProviding {
        var metricsByAccount: [UUID: UsageMetrics]
        var failingAccountIDs: Set<UUID> = []
        var probe: ConcurrencyProbe?

        init(metricsByAccount: [UUID: UsageMetrics]) {
            self.metricsByAccount = metricsByAccount
        }

        func canAccess(account: CodexAccount) async -> Bool {
            metricsByAccount[account.id] != nil
        }

        func fetchUsageMetrics(account: CodexAccount) async throws -> UsageMetrics {
            await probe?.recordFetch()
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
        fableTracker: ClaudeFableSessionTracking? = nil,
        codexAccountStore: CodexAccountStore? = nil,
        providerVisibilityStore: ProviderVisibilityStore? = nil,
        hidden: Set<ServiceType> = [],
        preload: [ServiceType: UsageMetrics] = [:],
        preloadClaudeAccountMetrics: [UUID: UsageMetrics] = [:],
        preloadSharedAccountMetrics: [AccountUsageSnapshot] = [],
        savedRefreshInterval: RefreshInterval? = nil,
        parseHealthStore: ProviderParseHealthStore? = nil,
        schedulesAutoRefresh: Bool = false,
        adaptiveNow: @escaping @Sendable () -> Date = { Date() },
        adaptivePowerState: @escaping @Sendable () -> AdaptiveRefreshPowerState = {
            .unconstrained
        },
        demoMode: Bool = false
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

        let visibility = providerVisibilityStore
            ?? ProviderVisibilityStore(userDefaults: visibilityDefaults)
        let hiddenProviders = claude == nil ? hidden.union([.claudeCode]) : hidden
        for service in hiddenProviders {
            visibility.set(service, isEnabled: false)
        }

        let sharedStore = SharedDataStore(directoryOverride: tempDirectory) {}
        if !preloadSharedAccountMetrics.isEmpty {
            sharedStore.saveAccountMetrics(preloadSharedAccountMetrics)
            sharedStore.flushPendingWrites()
        }

        let manager = UsageDataManager(
            codexCliService: codex,
            cursorService: cursor,
            claudeCodeService: claude ?? ClaudeCodeLocalService.shared,
            claudeCodeAccountStore: claudeCodeAccountStore,
            claudeFableSessionTracker: fableTracker ?? StubFableTracker(),
            codexAccountStore: codexAccountStore,
            providerVisibilityStore: visibility,
            sharedStore: sharedStore,
            preferences: cacheDefaults,
            cacheDefaults: cacheDefaults,
            parseHealthStore: parseHealthStore,
            schedulesAutoRefresh: schedulesAutoRefresh,
            adaptiveNow: adaptiveNow,
            adaptivePowerState: adaptivePowerState,
            demoMode: demoMode
        )
        return (manager, sharedStore)
    }

    // MARK: - Demo mode

    func testDemoModePublishesSyntheticMetricsAndNeverWritesTheSharedStore() async {
        let codex = StubProvider(hasAccess: true, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: true, result: .success(MetricsFixtures.cursor()))
        let (manager, sharedStore) = makeManager(codex: codex, cursor: cursor, demoMode: true)

        // Publishes the synthetic fixture rather than any real/cached account data.
        let expected = DemoData.metrics()
        XCTAssertEqual(Set(manager.metrics.keys), Set(expected.keys))
        XCTAssertEqual(manager.metrics[.codexCli]?.weeklyLimit?.used, 82)
        XCTAssertEqual(manager.metrics[.claudeCode]?.modelLimitLabel, "Fable")

        // The widget/CLI cache lives in a separate process; demo mode must never
        // clobber the real user's on-disk metrics.
        sharedStore.flushPendingWrites()
        XCTAssertTrue(sharedStore.loadMetrics().isEmpty)

        // Refreshing is a no-op that reports every provider as skipped-for-demo,
        // and still leaves the shared cache untouched.
        let report = await manager.refreshAll()
        XCTAssertEqual(report.outcome(for: .codexCli)?.state, .skipped)
        XCTAssertEqual(report.outcome(for: .cursor)?.state, .skipped)
        sharedStore.flushPendingWrites()
        XCTAssertTrue(sharedStore.loadMetrics().isEmpty)
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

        let report = await manager.refreshAll()

        XCTAssertEqual(health.records[.codexCli]?.consecutiveFailures, 0)
        XCTAssertEqual(health.records[.cursor]?.consecutiveFailures, 1)
        XCTAssertTrue(health.records[.cursor]?.lastFailureWasShapeMismatch ?? false)
        XCTAssertEqual(report.outcome(for: .codexCli)?.state, .refreshed)
        XCTAssertEqual(report.outcome(for: .cursor)?.state, .failed)
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

    func testRefreshAllThreadsRefreshTriggerToEveryClaudeAccount() async throws {
        let accountSuite = "UsageDataManagerTests-claude-trigger-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = ClaudeCodeAccountStore(userDefaults: accountDefaults)
        accountStore.addAccount(name: "Secondary", configDirectory: "/tmp/secondary-claude")
        let claude = StubClaudeProvider(
            hasAccess: true,
            result: .success(MetricsFixtures.claudeCode())
        )
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            claude: claude,
            claudeCodeAccountStore: accountStore,
            hidden: [.codexCli, .cursor, .openRouter, .grok]
        )

        await manager.refreshAll(trigger: .background)
        await manager.refreshAll(trigger: .userInitiated)

        XCTAssertEqual(
            claude.refreshTriggers,
            [.background, .background, .userInitiated, .userInitiated]
        )
    }

    func testRefreshAllDefaultsToBackgroundClaudeAccess() async throws {
        let accountSuite = "UsageDataManagerTests-default-claude-trigger-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = ClaudeCodeAccountStore(userDefaults: accountDefaults)
        let claude = StubClaudeProvider(
            hasAccess: true,
            result: .success(MetricsFixtures.claudeCode())
        )
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            claude: claude,
            claudeCodeAccountStore: accountStore,
            hidden: [.codexCli, .cursor, .openRouter, .grok]
        )

        await manager.refreshAll()

        XCTAssertEqual(claude.refreshTriggers, [.background])
    }

    func testClaudeRefreshAlsoRefreshesFableSessionsForEnabledProfiles() async throws {
        let accountSuite = "UsageDataManagerTests-fable-accounts-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = ClaudeCodeAccountStore(userDefaults: accountDefaults)
        accountStore.addAccount(name: "Secondary", configDirectory: "/tmp/secondary-claude")
        let fableTracker = StubFableTracker()
        let claude = StubClaudeProvider(
            hasAccess: true,
            result: .success(MetricsFixtures.claudeCode(sessionUsedPercent: 7))
        )
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            claude: claude,
            claudeCodeAccountStore: accountStore,
            fableTracker: fableTracker,
            hidden: [.codexCli, .cursor, .openRouter, .grok]
        )

        await manager.refreshAll()

        XCTAssertEqual(fableTracker.refreshedAccountIDs.count, 1)
        XCTAssertEqual(
            Set(try XCTUnwrap(fableTracker.refreshedAccountIDs.first)),
            Set(accountStore.enabledAccounts.map(\.id))
        )
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

    /// #292 phase 2 acceptance: a logged-out secondary profile keeps its
    /// last-known numbers, but its state must say Login required — not the
    /// green band those cached numbers would otherwise produce — while the
    /// healthy default profile beside it is left alone.
    func testLoggedOutSecondaryAccountKeepsCachedNumbersButReportsNeedsLogin() async throws {
        let accountSuite = "UsageDataManagerTests-claude-auth-state-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = ClaudeCodeAccountStore(userDefaults: accountDefaults)
        accountStore.addAccount(name: "Work", configDirectory: "/tmp/work-claude")
        let work = try XCTUnwrap(accountStore.enabledAccounts.first { !$0.isDefault })

        let claude = StubClaudeProvider(
            hasAccess: true,
            result: .success(MetricsFixtures.claudeCode(sessionUsedPercent: 41))
        )
        claude.resultsByAccount[work.id] = .failure(StubError.fetchFailed)
        // What the service observed while failing: no usable credential.
        claude.accountAuthStates = [
            ClaudeCodeAccount.defaultID: .connected(.oauth),
            work.id: .needsLogin
        ]
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            claude: claude,
            claudeCodeAccountStore: accountStore,
            hidden: [.codexCli, .cursor, .openRouter, .grok],
            preloadClaudeAccountMetrics: [work.id: MetricsFixtures.claudeCode(sessionUsedPercent: 12)]
        )

        await manager.refreshAll()

        XCTAssertEqual(
            manager.claudeCodeAccountMetrics[work.id]?.sessionLimit?.used,
            12,
            "The cached reading must survive so the card can still show numbers"
        )
        XCTAssertEqual(manager.claudeCodeAccountStates[work.id], .needsLogin)
        XCTAssertEqual(manager.claudeCodeAccountStates[ClaudeCodeAccount.defaultID], .connected(.oauth))

        let snapshots = ProviderSnapshotBuilder.snapshots(ProviderSnapshotBuilder.Input(
            metrics: [:],
            claudeAccounts: accountStore.accounts,
            claudeAccountMetrics: manager.claudeCodeAccountMetrics,
            enabledServices: [.claudeCode],
            claudeAccountStates: manager.claudeCodeAccountStates
        ))
        let workCard = try XCTUnwrap(snapshots.first { $0.accountID == work.id })
        XCTAssertEqual(workCard.band, .healthy, "12% used is genuinely healthy — that is the trap")
        XCTAssertEqual(ProviderCardPresentation.statusText(for: workCard), "Login required")
    }

    func testSingleClaudeRefreshPublishesLoggedOutSecondaryAccountState() async throws {
        let accountSuite = "UsageDataManagerTests-single-claude-state-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = ClaudeCodeAccountStore(userDefaults: accountDefaults)
        accountStore.addAccount(name: "Work", configDirectory: "/tmp/work-claude")
        let work = try XCTUnwrap(accountStore.enabledAccounts.first { !$0.isDefault })
        let claude = StubClaudeProvider(
            hasAccess: true,
            result: .success(MetricsFixtures.claudeCode(sessionUsedPercent: 41))
        )
        claude.resultsByAccount[work.id] = .failure(StubError.fetchFailed)
        claude.accountAuthStates = [
            ClaudeCodeAccount.defaultID: .connected(.oauth),
            work.id: .needsLogin
        ]
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            claude: claude,
            claudeCodeAccountStore: accountStore,
            hidden: [.codexCli, .cursor, .openRouter, .grok],
            preloadClaudeAccountMetrics: [
                work.id: MetricsFixtures.claudeCode(sessionUsedPercent: 12)
            ]
        )

        await manager.refresh(service: .claudeCode)

        XCTAssertEqual(manager.claudeCodeAccountStates[work.id], .needsLogin)
        XCTAssertEqual(
            manager.claudeCodeAccountStates[ClaudeCodeAccount.defaultID],
            .connected(.oauth)
        )
    }

    func testSingleClaudeRefreshClearsAccountStateWhenEveryAccountIsDisabled() async throws {
        let accountSuite = "UsageDataManagerTests-single-claude-disabled-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = ClaudeCodeAccountStore(userDefaults: accountDefaults)
        let claude = StubClaudeProvider(
            hasAccess: true,
            result: .success(MetricsFixtures.claudeCode())
        )
        claude.accountAuthStates = [ClaudeCodeAccount.defaultID: .connected(.oauth)]
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            claude: claude,
            claudeCodeAccountStore: accountStore,
            hidden: [.codexCli, .cursor, .openRouter, .grok]
        )
        await manager.refreshAll()
        XCTAssertFalse(manager.claudeCodeAccountStates.isEmpty)

        accountStore.setEnabled(false, for: ClaudeCodeAccount.defaultID)
        await manager.refresh(service: .claudeCode)

        XCTAssertTrue(manager.claudeCodeAccountMetrics.isEmpty)
        XCTAssertTrue(manager.claudeCodeAccountStates.isEmpty)
    }

    func testSingleDisabledClaudeProviderClearsAccountState() async throws {
        let visibilitySuite = "UsageDataManagerTests-single-claude-hidden-\(UUID().uuidString)"
        createdSuiteNames.append(visibilitySuite)
        let visibilityDefaults = try XCTUnwrap(UserDefaults(suiteName: visibilitySuite))
        let visibility = ProviderVisibilityStore(userDefaults: visibilityDefaults)
        let claude = StubClaudeProvider(
            hasAccess: true,
            result: .success(MetricsFixtures.claudeCode())
        )
        claude.accountAuthStates = [ClaudeCodeAccount.defaultID: .connected(.oauth)]
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            claude: claude,
            providerVisibilityStore: visibility,
            hidden: [.codexCli, .cursor, .openRouter, .grok]
        )
        await manager.refreshAll()
        XCTAssertFalse(manager.claudeCodeAccountStates.isEmpty)

        visibility.set(.claudeCode, isEnabled: false)
        await manager.refresh(service: .claudeCode)

        XCTAssertTrue(manager.claudeCodeAccountMetrics.isEmpty)
        XCTAssertTrue(manager.claudeCodeAccountStates.isEmpty)
    }

    /// A transient failure with a cached reading is a different story: nothing
    /// is wrong with the login, the numbers are just old.
    func testTransientFailureOverACachedReadingReportsStaleNotNeedsLogin() async throws {
        let accountSuite = "UsageDataManagerTests-claude-stale-state-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = ClaudeCodeAccountStore(userDefaults: accountDefaults)
        let cachedAt = MetricsFixtures.referenceDate
        let cached = MetricsFixtures.claudeCode(sessionUsedPercent: 23)
        let claude = StubClaudeProvider(hasAccess: true, result: .failure(StubError.fetchFailed))
        claude.accountAuthStates = [ClaudeCodeAccount.defaultID: .connected(.oauth)]
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            claude: claude,
            claudeCodeAccountStore: accountStore,
            hidden: [.codexCli, .cursor, .openRouter, .grok],
            preloadClaudeAccountMetrics: [ClaudeCodeAccount.defaultID: cached]
        )

        await manager.refreshAll()

        XCTAssertEqual(
            manager.claudeCodeAccountStates[ClaudeCodeAccount.defaultID],
            .stale(since: cachedAt)
        )
    }

    func testRefreshAllPreservesSharedClaudeAccountSnapshotOnColdCLICacheFailure() async throws {
        let accountSuite = "UsageDataManagerTests-claude-shared-cache-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = ClaudeCodeAccountStore(userDefaults: accountDefaults)
        let cached = MetricsFixtures.claudeCode(sessionUsedPercent: 31)
        let claude = StubClaudeProvider(hasAccess: true, result: .failure(StubError.fetchFailed))
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let snapshot = AccountUsageSnapshot(
            id: ClaudeCodeAccount.defaultID,
            name: ClaudeCodeAccount.defaultName,
            metrics: cached
        )
        let (manager, sharedStore) = makeManager(
            codex: codex,
            cursor: cursor,
            claude: claude,
            claudeCodeAccountStore: accountStore,
            hidden: [.codexCli, .cursor, .openRouter, .grok],
            preloadSharedAccountMetrics: [snapshot]
        )

        await manager.refreshAll()

        XCTAssertEqual(
            manager.claudeCodeAccountMetrics[ClaudeCodeAccount.defaultID]?.sessionLimit?.used,
            31
        )
        sharedStore.flushPendingWrites()
        let persisted = try XCTUnwrap(sharedStore.loadAccountMetrics().first)
        XCTAssertEqual(persisted.id, ClaudeCodeAccount.defaultID)
        XCTAssertEqual(persisted.metrics.sessionLimit?.used, 31)
    }

    func testRefreshAllPreservesFailedCodexAccountFromSharedSnapshotOnColdCLICache() async throws {
        let accountSuite = "UsageDataManagerTests-codex-shared-cache-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = CodexAccountStore(userDefaults: accountDefaults)
        accountStore.addAccount(name: "Work", homeDirectory: "/tmp/codex-work")
        let work = try XCTUnwrap(accountStore.customAccounts.first)
        let provider = MultiAccountCodexProvider(metricsByAccount: [
            CodexAccount.defaultID: MetricsFixtures.codexCli(sessionUsedPercent: 20),
            work.id: MetricsFixtures.codexCli(sessionUsedPercent: 80),
        ])
        provider.failingAccountIDs = [work.id]
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let sharedSnapshots = [
            AccountUsageSnapshot(
                id: CodexAccount.defaultID,
                name: CodexAccount.defaultName,
                metrics: MetricsFixtures.codexCli(sessionUsedPercent: 15)
            ),
            AccountUsageSnapshot(
                id: work.id,
                name: "Work",
                metrics: MetricsFixtures.codexCli(sessionUsedPercent: 75)
            ),
        ]
        let (manager, sharedStore) = makeManager(
            codex: provider,
            cursor: cursor,
            codexAccountStore: accountStore,
            preloadSharedAccountMetrics: sharedSnapshots
        )

        await manager.refreshAll()

        XCTAssertEqual(manager.codexAccountMetrics[CodexAccount.defaultID]?.sessionLimit?.used, 20)
        XCTAssertEqual(manager.codexAccountMetrics[work.id]?.sessionLimit?.used, 75)
        sharedStore.flushPendingWrites()
        let persisted = Dictionary(
            uniqueKeysWithValues: sharedStore.loadAccountMetrics().map { ($0.id, $0.metrics) }
        )
        XCTAssertEqual(persisted[CodexAccount.defaultID]?.sessionLimit?.used, 20)
        XCTAssertEqual(persisted[work.id]?.sessionLimit?.used, 75)
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
            .adaptive,
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

    func testEveryFixedIntervalKeepsItsRepeatingTimerCadence() throws {
        let fixedIntervals: [RefreshInterval] = [
            .oneMinute,
            .twoMinutes,
            .fiveMinutes,
            .tenMinutes,
            .fifteenMinutes,
            .thirtyMinutes,
        ]

        for fixedInterval in fixedIntervals {
            let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
            let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
            let (manager, _) = makeManager(
                codex: codex,
                cursor: cursor,
                savedRefreshInterval: fixedInterval,
                schedulesAutoRefresh: true
            )

            XCTAssertEqual(
                try XCTUnwrap(manager.scheduledRefreshInterval),
                fixedInterval.seconds,
                accuracy: 0.01
            )
            XCTAssertTrue(manager.scheduledRefreshRepeats)
        }
    }

    func testAdaptiveSchedulerStartsIdleAndReschedulesAfterExplicitInteraction() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            savedRefreshInterval: .adaptive,
            schedulesAutoRefresh: true,
            adaptiveNow: { now }
        )

        XCTAssertEqual(try XCTUnwrap(manager.scheduledRefreshInterval), 1_800, accuracy: 0.01)
        XCTAssertFalse(manager.scheduledRefreshRepeats)

        await manager.refreshForExplicitAction(.manualRefresh)

        XCTAssertEqual(try XCTUnwrap(manager.scheduledRefreshInterval), 120, accuracy: 0.01)
        XCTAssertEqual(manager.effectiveRefreshReason, AdaptiveRefreshReason.recentInteraction.displayText)
    }

    func testAdaptiveSchedulerReschedulesToFastBoundWhenQuotaMoves() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let cached = UsageMetrics(
            service: .cursor,
            weeklyLimit: UsageLimit(used: 10, total: 100, resetTime: nil),
            lastUpdated: now.addingTimeInterval(-60)
        )
        let refreshed = UsageMetrics(
            service: .cursor,
            weeklyLimit: UsageLimit(used: 11, total: 100, resetTime: nil),
            lastUpdated: now
        )
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: true, result: .success(refreshed))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            hidden: [.codexCli],
            preload: [.cursor: cached],
            savedRefreshInterval: .adaptive,
            schedulesAutoRefresh: true,
            adaptiveNow: { now }
        )

        await manager.refreshAll()

        XCTAssertEqual(try XCTUnwrap(manager.scheduledRefreshInterval), 60, accuracy: 0.01)
        XCTAssertEqual(manager.effectiveRefreshReason, AdaptiveRefreshReason.recentQuotaMovement.displayText)
    }

    /// Reset-credit publish skips refresh methods; movement must still reschedule Adaptive.
    func testAdaptiveSchedulerReschedulesWhenResetCreditPublishMovesQuota() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let cached = MetricsFixtures.codexCli(sessionUsedPercent: 40)
        let codex = StubProvider(hasAccess: true, result: .success(cached))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            preload: [.codexCli: cached],
            savedRefreshInterval: .adaptive,
            schedulesAutoRefresh: true,
            adaptiveNow: { now }
        )

        XCTAssertEqual(try XCTUnwrap(manager.scheduledRefreshInterval), 1_800, accuracy: 0.01)

        manager.applyCodexResetCreditRefresh(
            MetricsFixtures.codexCli(sessionUsedPercent: 0, resetCreditsAvailable: 0),
            accountID: CodexAccount.defaultID
        )

        XCTAssertEqual(try XCTUnwrap(manager.scheduledRefreshInterval), 60, accuracy: 0.01)
        XCTAssertEqual(manager.effectiveRefreshReason, AdaptiveRefreshReason.recentQuotaMovement.displayText)
    }

    func testAdaptiveSchedulerUsesInjectedPowerAndThermalSignals() {
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            savedRefreshInterval: .adaptive,
            schedulesAutoRefresh: true,
            adaptivePowerState: {
                AdaptiveRefreshPowerState(
                    isOnBattery: false,
                    isLowPowerModeEnabled: false,
                    thermalState: .serious
                )
            }
        )

        XCTAssertEqual(manager.scheduledRefreshInterval, 1_800)
        XCTAssertEqual(manager.effectiveRefreshReason, AdaptiveRefreshReason.thermalPressure.displayText)
    }

    func testExplicitActionsBypassCadenceWithoutMakingPopoverCredentialReadsInteractive() async {
        let claude = StubClaudeProvider(
            hasAccess: true,
            result: .success(MetricsFixtures.claudeCode())
        )
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            claude: claude,
            savedRefreshInterval: .adaptive
        )

        await manager.refreshForExplicitAction(.popoverOpened)
        await manager.refreshForExplicitAction(.manualRefresh)

        XCTAssertEqual(claude.refreshTriggers, [.background, .userInitiated])
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
            _ = await firstRefresh.value
            return XCTFail("the first refresh should be suspended inside the provider fetch")
        }

        await manager.refreshAll()

        XCTAssertEqual(cursor.fetchCount, 1)
        cursor.resumeFetch()
        _ = await firstRefresh.value
        XCTAssertFalse(manager.isLoading)
    }

    // MARK: - Refresh generation

    /// `refreshGeneration` is the notification layer's trigger: it must advance
    /// exactly once for every committed snapshot, so a subscriber can re-evaluate
    /// limits on real change instead of polling a timer.
    func testRefreshGenerationAdvancesOncePerCommittedSnapshot() async {
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: true, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(codex: codex, cursor: cursor)

        XCTAssertEqual(manager.refreshGeneration, 0)

        await manager.refreshAll()
        XCTAssertEqual(manager.refreshGeneration, 1)

        await manager.refresh(service: .cursor)
        XCTAssertEqual(manager.refreshGeneration, 2)
    }

    func testRefreshGenerationDoesNotAdvanceForASkippedOverlappingCycle() async {
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
            _ = await firstRefresh.value
            return XCTFail("the first refresh should be suspended inside the provider fetch")
        }

        // The overlapping call returns without committing anything.
        await manager.refreshAll()
        XCTAssertEqual(manager.refreshGeneration, 0)

        cursor.resumeFetch()
        _ = await firstRefresh.value
        XCTAssertEqual(manager.refreshGeneration, 1)
    }

    /// Clearing a provider that was just turned off is a committed change even
    /// though nothing was fetched — subscribers must see it.
    func testRefreshGenerationAdvancesWhenADisabledProviderIsCleared() async {
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: true, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            hidden: [.cursor],
            preload: [.cursor: MetricsFixtures.cursor()]
        )

        await manager.refresh(service: .cursor)

        XCTAssertEqual(cursor.fetchCount, 0)
        XCTAssertNil(manager.metrics[.cursor])
        XCTAssertEqual(manager.refreshGeneration, 1)
    }

    func testRefreshGenerationAdvancesForCodexResetCreditRefresh() {
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(codex: codex, cursor: cursor)

        manager.applyCodexResetCreditRefresh(MetricsFixtures.codexCli(), accountID: CodexAccount.defaultID)

        XCTAssertEqual(manager.refreshGeneration, 1)
    }

    func testRefreshGenerationPublishesEveryCommitToSubscribers() async {
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: true, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(codex: codex, cursor: cursor)
        var observed: [UInt64] = []
        let cancellable = manager.$refreshGeneration.dropFirst().sink { observed.append($0) }

        await manager.refreshAll()
        await manager.refreshAll()

        XCTAssertEqual(observed, [1, 2])
        withExtendedLifetime(cancellable) {}
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

        let report = await manager.refreshAll()

        // Codex refreshed; Cursor degraded gracefully to its cached value.
        XCTAssertEqual(Set(manager.metrics.keys), [.codexCli, .cursor])
        XCTAssertEqual(manager.metrics[.cursor]?.weeklyLimit?.used, 999)
        XCTAssertNotNil(manager.lastError)
        XCTAssertEqual(report.outcome(for: .codexCli)?.state, .refreshed)
        XCTAssertEqual(report.outcome(for: .cursor)?.state, .failed)
        XCTAssertEqual(report.outcome(for: .cursor)?.servedFromCache, true)
        XCTAssertEqual(report.outcome(for: .cursor)?.lastUpdated, cachedCursor.lastUpdated)
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

    // MARK: - Concurrency

    /// A refresh used to walk every account and provider strictly serially, so
    /// a cycle cost the sum of every round trip. `ConcurrencyProbe` fails these
    /// by observing `maxInFlight == 1`; it can never hang a serial build
    /// because its wait is a bounded yield loop.
    func testRefreshAllFetchesEveryEnabledClaudeAccountConcurrently() async throws {
        let accountSuite = "UsageDataManagerTests-claude-concurrency-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = ClaudeCodeAccountStore(userDefaults: accountDefaults)
        accountStore.addAccount(name: "Work", configDirectory: "/tmp/claude-work")
        let probe = ConcurrencyProbe(expected: 2)
        let claude = StubClaudeProvider(hasAccess: true, result: .success(MetricsFixtures.claudeCode()))
        claude.probe = probe
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            claude: claude,
            claudeCodeAccountStore: accountStore,
            hidden: [.codexCli, .cursor, .openRouter, .grok]
        )

        await manager.refreshAll()

        XCTAssertEqual(claude.fetchCount, 2)
        XCTAssertEqual(probe.maxInFlight, 2, "both Claude accounts must be in flight at once")
    }

    func testRefreshAllFetchesEveryEnabledCodexAccountConcurrently() async throws {
        let accountSuite = "UsageDataManagerTests-codex-concurrency-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = CodexAccountStore(userDefaults: accountDefaults)
        accountStore.addAccount(name: "Work", homeDirectory: "/tmp/codex-work")
        let work = try XCTUnwrap(accountStore.customAccounts.first)
        let provider = MultiAccountCodexProvider(metricsByAccount: [
            CodexAccount.defaultID: MetricsFixtures.codexCli(sessionUsedPercent: 20),
            work.id: MetricsFixtures.codexCli(sessionUsedPercent: 80)
        ])
        let probe = ConcurrencyProbe(expected: 2)
        provider.probe = probe
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: provider,
            cursor: cursor,
            codexAccountStore: accountStore,
            hidden: [.cursor, .openRouter, .grok]
        )

        await manager.refreshAll()

        XCTAssertEqual(probe.maxInFlight, 2, "both Codex accounts must be in flight at once")
    }

    /// The three phases of `refreshAll` — Claude accounts, Codex accounts, the
    /// single-account providers — must overlap with each other too, not just
    /// internally, or the cycle still costs three serial round trips.
    func testRefreshAllOverlapsClaudeCodexAndSimpleProviderFetches() async throws {
        let codexSuite = "UsageDataManagerTests-overlap-codex-\(UUID().uuidString)"
        createdSuiteNames.append(codexSuite)
        let codexDefaults = try XCTUnwrap(UserDefaults(suiteName: codexSuite))
        let codexStore = CodexAccountStore(userDefaults: codexDefaults)
        let probe = ConcurrencyProbe(expected: 3)
        let claude = StubClaudeProvider(hasAccess: true, result: .success(MetricsFixtures.claudeCode()))
        claude.probe = probe
        let codex = MultiAccountCodexProvider(metricsByAccount: [
            CodexAccount.defaultID: MetricsFixtures.codexCli()
        ])
        codex.probe = probe
        let cursor = StubProvider(hasAccess: true, result: .success(MetricsFixtures.cursor()))
        cursor.probe = probe
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            claude: claude,
            codexAccountStore: codexStore,
            hidden: [.openRouter, .grok]
        )

        await manager.refreshAll()

        XCTAssertEqual(probe.maxInFlight, 3, "Claude, Codex and simple-provider fetches must overlap")
    }

    /// Concurrency must not scramble attribution: the reported failure is still
    /// the *first enabled account's*, not whichever leg happened to finish
    /// first, so the surfaced reason is stable across runs.
    func testRefreshAllAttributesClaudeFailuresInAccountOrderDespiteConcurrency() async throws {
        XCTAssertNotEqual(
            ServiceSupport.safeErrorMessage(for: ServiceError.parsingError),
            ServiceSupport.safeErrorMessage(for: StubError.fetchFailed),
            "fixture guard: the two failures must be distinguishable"
        )
        let accountSuite = "UsageDataManagerTests-claude-failure-order-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = ClaudeCodeAccountStore(userDefaults: accountDefaults)
        accountStore.addAccount(name: "Work", configDirectory: "/tmp/claude-work")
        let work = try XCTUnwrap(accountStore.customAccounts.first)
        let claude = StubClaudeProvider(hasAccess: true, result: .failure(StubError.fetchFailed))
        claude.resultsByAccount = [
            ClaudeCodeAccount.defaultID: .failure(ServiceError.parsingError),
            work.id: .failure(StubError.fetchFailed)
        ]
        claude.probe = ConcurrencyProbe(expected: 2)
        let codex = StubProvider(hasAccess: false, result: .success(MetricsFixtures.codexCli()))
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: codex,
            cursor: cursor,
            claude: claude,
            claudeCodeAccountStore: accountStore,
            hidden: [.codexCli, .cursor, .openRouter, .grok]
        )

        let report = await manager.refreshAll()

        XCTAssertEqual(report.outcome(for: .claudeCode)?.state, .failed)
        XCTAssertEqual(
            report.outcome(for: .claudeCode)?.reason,
            ServiceSupport.safeErrorMessage(for: ServiceError.parsingError),
            "the first enabled account's failure must win regardless of completion order"
        )
    }

    /// `lastError` must be a property of the inputs, not of scheduling. The
    /// three phases race, so whichever finishes last must not get to claim the
    /// surfaced error: Claude outranks Codex outranks the simple providers,
    /// every run.
    func testRefreshAllSurfacesClaudeFailureAheadOfConcurrentPhases() async throws {
        let (manager, _) = try makeAllPhasesFailingManager(
            claudeResult: .failure(TaggedError(tag: "claude")),
            codexResult: .failure(TaggedError(tag: "codex"))
        )

        await manager.refreshAll()

        XCTAssertEqual(
            (manager.lastError as? TaggedError)?.tag,
            "claude",
            "the Claude phase outranks the others regardless of completion order"
        )
    }

    /// Same ordering guarantee one rung down: with Claude healthy, the Codex
    /// phase's failure wins over the simple providers'.
    func testRefreshAllSurfacesCodexFailureAheadOfSimpleProviders() async throws {
        let (manager, _) = try makeAllPhasesFailingManager(
            claudeResult: .success(MetricsFixtures.claudeCode()),
            codexResult: .failure(TaggedError(tag: "codex"))
        )

        await manager.refreshAll()

        XCTAssertEqual(
            (manager.lastError as? TaggedError)?.tag,
            "codex",
            "the Codex phase outranks the simple providers regardless of completion order"
        )
    }

    /// Builds a manager whose three refresh phases all run — and whose simple
    /// provider always fails — so a test only has to say how Claude and Codex
    /// behave. The shared probe holds every leg open until all three are in
    /// flight, which is what makes completion order genuinely non-deterministic.
    private func makeAllPhasesFailingManager(
        claudeResult: Result<UsageMetrics, Error>,
        codexResult: Result<UsageMetrics, Error>
    ) throws -> (manager: UsageDataManager, sharedStore: SharedDataStore) {
        let accountSuite = "UsageDataManagerTests-phase-order-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let probe = ConcurrencyProbe(expected: 3)

        let claude = StubClaudeProvider(hasAccess: true, result: claudeResult)
        claude.probe = probe
        let codex = StubProvider(hasAccess: true, result: codexResult)
        codex.probe = probe
        let cursor = StubProvider(hasAccess: true, result: .failure(TaggedError(tag: "simple")))
        cursor.probe = probe

        return makeManager(
            codex: codex,
            cursor: cursor,
            claude: claude,
            claudeCodeAccountStore: ClaudeCodeAccountStore(userDefaults: accountDefaults),
            hidden: [.openRouter, .grok]
        )
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

    /// Redemption is scoped to the card that acted: refreshing one Codex profile
    /// must leave every other profile's cached metrics exactly as they were.
    func testApplyResetCreditRefreshOnlyTouchesTheRedeemingAccount() async throws {
        let accountSuite = "UsageDataManagerTests-reset-credit-scope-\(UUID().uuidString)"
        createdSuiteNames.append(accountSuite)
        let accountDefaults = try XCTUnwrap(UserDefaults(suiteName: accountSuite))
        let accountStore = CodexAccountStore(userDefaults: accountDefaults)
        accountStore.addAccount(name: "Work", homeDirectory: "/tmp/codex-work")
        let work = try XCTUnwrap(accountStore.customAccounts.first)
        let provider = MultiAccountCodexProvider(metricsByAccount: [
            CodexAccount.defaultID: MetricsFixtures.codexCli(sessionUsedPercent: 20, resetCreditsAvailable: 2),
            work.id: MetricsFixtures.codexCli(sessionUsedPercent: 100, resetCreditsAvailable: 2)
        ])
        let cursor = StubProvider(hasAccess: false, result: .success(MetricsFixtures.cursor()))
        let (manager, _) = makeManager(
            codex: provider,
            cursor: cursor,
            codexAccountStore: accountStore
        )

        await manager.refreshAll()
        manager.applyCodexResetCreditRefresh(
            MetricsFixtures.codexCli(sessionUsedPercent: 0, resetCreditsAvailable: 1),
            accountID: work.id
        )

        XCTAssertEqual(manager.codexAccountMetrics[work.id]?.sessionLimit?.used, 0)
        XCTAssertEqual(manager.codexAccountMetrics[work.id]?.resetCreditsAvailable, 1)
        XCTAssertEqual(manager.codexAccountMetrics[CodexAccount.defaultID]?.sessionLimit?.used, 20)
        XCTAssertEqual(manager.codexAccountMetrics[CodexAccount.defaultID]?.resetCreditsAvailable, 2)
    }
}
