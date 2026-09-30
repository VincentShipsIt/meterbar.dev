import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

@MainActor
final class UsageRefreshCLIFactoryTests: XCTestCase {

    // MARK: Internal

    override func tearDownWithError() throws {
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        for directory in directories {
            try FileManager.default.removeItem(at: directory)
        }
        suiteNames = []
        directories = []
    }

    func testFactoryRefreshesOnlyConfiguredEnabledKeysInProjectedOrder() async throws {
        let first = OpenRouterAccount(id: UUID(), name: "First key")
        let second = OpenRouterAccount(id: UUID(), name: "Second key")
        let disabled = OpenRouterAccount(id: UUID(), name: "Disabled key", isEnabled: false)
        var defaultAccount = OpenRouterAccount.defaultAccount
        defaultAccount.name = "Renamed default"
        defaultAccount.isEnabled = false
        let fixture = try makeFixture(accounts: [second, defaultAccount, disabled, first])

        await fixture.manager.refreshAll()
        fixture.store.flushPendingWrites()

        XCTAssertEqual(Set(fixture.provider.fetched.map(\.id)), Set([second.id, first.id]))
        XCTAssertEqual(Set(fixture.provider.probed.map(\.id)), Set([second.id, first.id]))
        XCTAssertEqual(Set(fixture.manager.openRouterAccountMetrics.keys), Set([second.id, first.id]))
        XCTAssertEqual(fixture.manager.metrics[.openRouter]?.sessionLimit?.used, 20)
        XCTAssertEqual(fixture.store.loadMetrics()[.openRouter]?.sessionLimit?.used, 20)
        let snapshots = fixture.store.loadAccountMetrics()
        XCTAssertEqual(snapshots.map(\.id), [second.id, first.id])
        XCTAssertEqual(snapshots.map(\.name), ["Second key", "First key"])
        XCTAssertEqual(snapshots.map(\.metrics.service), [.openRouter, .openRouter])
    }

    func testFactoryUsesExplicitRenamedDefaultAndPreservesItsSnapshot() async throws {
        var account = OpenRouterAccount.defaultAccount
        account.name = "Configured default"
        let fixture = try makeFixture(accounts: [account])

        await fixture.manager.refreshAll()
        fixture.store.flushPendingWrites()

        XCTAssertEqual(fixture.provider.fetched, [account])
        let snapshot = try XCTUnwrap(fixture.store.loadAccountMetrics().first)
        XCTAssertEqual(snapshot.id, account.id)
        XCTAssertEqual(snapshot.name, "Configured default")
        XCTAssertEqual(snapshot.metrics.service, .openRouter)
        XCTAssertEqual(snapshot.metrics.sessionLimit?.used, fixture.manager.metrics[.openRouter]?.sessionLimit?.used)
        XCTAssertEqual(snapshot.metrics.lastUpdated, fixture.manager.metrics[.openRouter]?.lastUpdated)
    }

    func testFactoryDoesNotRefreshAbsentDefaultWithCustomOnlyProjection() async throws {
        let account = OpenRouterAccount(id: UUID(), name: "Only key")
        let fixture = try makeFixture(accounts: [account])

        await fixture.manager.refreshAll()
        fixture.store.flushPendingWrites()

        XCTAssertEqual(fixture.provider.fetched, [account])
        XCTAssertEqual(fixture.store.loadAccountMetrics().map(\.id), [account.id])
    }

    func testFactoryDoesNotProbeOrFetchAnEmptyAuthoritativeProjection() async throws {
        let fixture = try makeFixture(accounts: [])

        await fixture.manager.refreshAll()
        fixture.store.flushPendingWrites()

        XCTAssertTrue(fixture.provider.probed.isEmpty)
        XCTAssertTrue(fixture.provider.fetched.isEmpty)
        XCTAssertTrue(fixture.manager.openRouterAccountMetrics.isEmpty)
        XCTAssertNil(fixture.manager.metrics[.openRouter])
        XCTAssertNil(fixture.store.loadMetrics()[.openRouter])
        XCTAssertTrue(fixture.store.loadAccountMetrics().isEmpty)
    }

    // MARK: Private

    private struct Fixture {
        let manager: UsageDataManager
        let store: SharedDataStore
        let provider: OpenRouterProvider
    }

    private final class OpenRouterProvider: OpenRouterUsageProviding {

        // MARK: Lifecycle

        init(accounts: [OpenRouterAccount]) {
            self.metrics = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { index, account in
                (account.id, UsageMetrics(
                    service: .openRouter,
                    sessionLimit: UsageLimit(used: Double(index + 1) * 20, total: 100, resetTime: nil)
                ))
            })
        }

        // MARK: Internal

        private(set) var probed: [OpenRouterAccount] = []
        private(set) var fetched: [OpenRouterAccount] = []

        /// No observations means no production ledger read/write.
        var latestAccountObservations: [UUID: ProviderUsageObservation] {
            [:]
        }

        func canAccess(account: OpenRouterAccount) -> Bool {
            probed.append(account)
            return true
        }

        func fetchUsageMetrics(account: OpenRouterAccount) async throws -> UsageMetrics {
            fetched.append(account)
            return try XCTUnwrap(metrics[account.id], "Factory fetched an unconfigured key")
        }

        // MARK: Private

        private let metrics: [UUID: UsageMetrics]

    }

    private final class UnusedProvider: SimpleUsageProviding, CodexUsageProviding,
        GrokUsageProviding, ClaudeCodeUsageProviding {

        // MARK: Internal

        var hasAccess: Bool {
            false
        }

        var accountAuthStates: [UUID: ClaudeCodeAuthState] {
            [:]
        }

        var latestUsageObservation: ProviderUsageObservation? {
            nil
        }

        nonisolated func canAccess(account _: CodexAccount) async -> Bool {
            false
        }

        func canAccess(account _: GrokAccount) -> Bool {
            false
        }

        func fetchUsageMetrics() async throws -> UsageMetrics {
            try unexpectedFetch()
        }

        func fetchUsageMetrics(account _: CodexAccount) async throws -> UsageMetrics {
            try unexpectedFetch()
        }

        func fetchUsageMetrics(account _: GrokAccount) async throws -> UsageMetrics {
            try unexpectedFetch()
        }

        func fetchUsageMetrics(account _: ClaudeCodeAccount) async throws -> UsageMetrics {
            try unexpectedFetch()
        }

        // MARK: Private

        private func unexpectedFetch() throws -> UsageMetrics {
            XCTFail("A hidden provider must not be fetched")
            throw ServiceError.notAuthenticated
        }
    }

    private struct NoCredentialSwitcher: AccountCredentialSwitching {
        func switchCredentials(for _: AccountFailoverEvent) async throws {
            XCTFail("Factory fixtures must not switch credentials")
        }
    }

    private struct NoNotifier: AccountFailoverNotifying {
        func prepareForAutomaticSwitch() async -> Bool {
            XCTFail("Factory fixtures must not request notification permission")
            return false
        }

        func notify(_: AccountFailoverEvent) async -> Bool {
            XCTFail("Factory fixtures must not notify")
            return false
        }
    }

    private var suiteNames: [String] = []
    private var directories: [URL] = []

    private func makeFixture(accounts: [OpenRouterAccount]) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageRefreshCLIFactoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let defaults = try makeDefaults()
        let store = SharedDataStore(directoryOverride: directory) {}
        let unused = UnusedProvider()
        let provider = OpenRouterProvider(accounts: accounts)
        let failover = try AccountFailoverCoordinator(
            settings: AccountFailoverSettingsStore(userDefaults: makeDefaults()),
            claudeAccounts: ClaudeCodeAccountStore(accounts: []),
            codexAccounts: CodexAccountStore(accounts: []),
            credentialSwitcher: NoCredentialSwitcher(),
            notifier: NoNotifier()
        )
        let dependencies = UsageRefreshCLI.ManagerDependencies(
            codex: unused,
            cursor: unused,
            openRouter: provider,
            grok: unused,
            claude: unused,
            preferences: defaults,
            cacheDefaults: defaults,
            parseHealth: ProviderParseHealthStore(userDefaults: defaults, sharedDirectoryOverride: directory),
            failover: failover
        )
        let configuration = UsageRefreshConfigurationStore.Snapshot(
            hiddenServices: Set(ServiceType.allCases).subtracting([.openRouter]),
            claudeAccounts: [],
            codexAccounts: [],
            grokAccounts: [],
            openRouterAccounts: accounts
        )
        let manager = UsageRefreshCLI.makeManager(
            sharedStore: store,
            configuration: configuration,
            dependencies: dependencies
        )
        return Fixture(manager: manager, store: store, provider: provider)
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "UsageRefreshCLIFactoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        suiteNames.append(name)
        return defaults
    }

}
