import Foundation
import MeterBarShared
import Security
import XCTest
@testable import MeterBar

// MARK: - Keychain layout

final class OpenRouterKeychainLayoutTests: XCTestCase {
    /// The default account keeps the legacy single-key item name so pre-multi-key
    /// installs migrate without copying or rewriting anything.
    func testDefaultAccountUsesTheLegacySingleKeyName() {
        XCTAssertEqual(
            OpenRouterService.keychainKey(for: OpenRouterAccount.defaultID),
            OpenRouterService.keychainKey
        )
    }

    func testCustomAccountsGetPerAccountItemNames() {
        let id = UUID()
        XCTAssertNotEqual(OpenRouterService.keychainKey(for: id), OpenRouterService.keychainKey)
        XCTAssertTrue(OpenRouterService.keychainKey(for: id).hasPrefix(OpenRouterService.keychainKey))
        XCTAssertEqual(
            OpenRouterService.keychainKey(for: id),
            OpenRouterService.keychainKey(for: id),
            "item names must be stable across launches"
        )
    }

    func testSaveHasAndRemoveRoundTripPerAccount() {
        let keychain = KeychainManager(
            backend: SeededKeychainBackend(),
            currentService: "test.openrouter.layout"
        )
        let service = OpenRouterService(keychain: keychain)
        let first = UUID()
        let second = UUID()

        XCTAssertFalse(service.hasKey(for: first))
        XCTAssertTrue(service.saveAPIKey("sk-or-v1-a", for: first))
        XCTAssertTrue(service.saveAPIKey("sk-or-v1-b", for: second))

        XCTAssertTrue(service.hasKey(for: first))
        XCTAssertTrue(service.hasKey(for: second))
        XCTAssertEqual(keychain.get(key: OpenRouterService.keychainKey(for: first)), "sk-or-v1-a")
        XCTAssertEqual(keychain.get(key: OpenRouterService.keychainKey(for: second)), "sk-or-v1-b")

        XCTAssertTrue(service.removeAPIKey(for: first))
        XCTAssertFalse(service.hasKey(for: first))
        XCTAssertTrue(service.hasKey(for: second), "removing one key must not touch its peers")
    }

    /// An existing 1.8.x single key is the default account's key with no
    /// migration step: the legacy item simply *is* the default account's item.
    func testLegacySingleKeyIsReadableThroughTheDefaultAccount() {
        let keychain = KeychainManager(
            backend: SeededKeychainBackend(),
            currentService: "test.openrouter.legacy"
        )
        XCTAssertTrue(keychain.save(key: OpenRouterService.keychainKey, value: "sk-or-v1-legacy"))

        let service = OpenRouterService(keychain: keychain)
        XCTAssertTrue(service.canAccess(account: OpenRouterAccount.defaultAccount))
    }
}

// MARK: - Ledger aggregation

final class OpenRouterAggregatedObservationTests: XCTestCase {
    private func observation(running: Double, daily: Double?) -> ProviderUsageObservation {
        ProviderUsageObservation(
            provider: .openRouter,
            unit: .usd,
            runningTotal: running,
            authoritativeDailyTotal: daily,
            dayBoundary: .utc,
            observedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testSumsRunningTotalsAcrossKeys() throws {
        let aggregated = try XCTUnwrap(OpenRouterService.aggregatedObservation(
            [observation(running: 10, daily: 1), observation(running: 2.5, daily: 0.5)],
            observedAt: Date(timeIntervalSince1970: 100)
        ))
        XCTAssertEqual(aggregated.runningTotal, 12.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(aggregated.authoritativeDailyTotal), 1.5, accuracy: 0.0001)
        XCTAssertEqual(aggregated.provider, .openRouter)
        XCTAssertEqual(aggregated.unit, .usd)
        XCTAssertEqual(aggregated.dayBoundary, .utc)
    }

    /// A partial `usage_daily` sum would understate the day while looking
    /// authoritative — a missing report falls back to the delta path instead.
    func testMissingDailyOnAnyKeyDropsTheAuthoritativeTotal() throws {
        let aggregated = try XCTUnwrap(OpenRouterService.aggregatedObservation(
            [observation(running: 10, daily: 1), observation(running: 2.5, daily: nil)],
            observedAt: Date(timeIntervalSince1970: 100)
        ))
        XCTAssertEqual(aggregated.runningTotal, 12.5, accuracy: 0.0001)
        XCTAssertNil(aggregated.authoritativeDailyTotal)
    }

    func testEmptyPollProducesNoObservation() {
        XCTAssertNil(OpenRouterService.aggregatedObservation([], observedAt: Date()))
    }
}

// MARK: - Account store

final class OpenRouterAccountStoreTests: XCTestCase {
    private func makeStore() -> (OpenRouterAccountStore, UserDefaults) {
        let suiteName = "OpenRouterAccountStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return (OpenRouterAccountStore(accounts: [.defaultAccount]), .standard)
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (OpenRouterAccountStore(userDefaults: defaults, refreshConfigurationDirectory: nil), defaults)
    }

    private func addKey(_ store: OpenRouterAccountStore, _ name: String) -> OpenRouterAccount {
        guard let account = store.addAccount(name: name) else {
            return OpenRouterAccount(id: OpenRouterAccount.defaultID, name: name)
        }
        return account
    }

    func testAddAccountReturnsAnIdentifiedAccountAndPersistsIt() {
        let (store, defaults) = makeStore()
        let account = store.addAccount(name: "Work")

        let created = try? XCTUnwrap(account)
        guard let created else { return }
        XCTAssertEqual(created.name, "Work")
        XCTAssertFalse(created.isDefault)
        XCTAssertEqual(store.accounts.count, 2)

        // Persists across a fresh store over the same defaults.
        let reloaded = OpenRouterAccountStore(userDefaults: defaults, refreshConfigurationDirectory: nil)
        XCTAssertEqual(reloaded.customAccounts.map(\.id), [created.id])
    }

    func testAddAccountRejectsBlankNames() {
        let (store, _) = makeStore()
        XCTAssertNil(store.addAccount(name: "   "))
        XCTAssertEqual(store.accounts.count, 1)
    }

    func testLastEnabledKeyCannotBeDisabledOrRemoved() {
        let (store, _) = makeStore()
        let account = addKey(store, "Only")

        // With both enabled, either can be disabled; the guard bites only when
        // one would leave zero enabled keys.
        XCTAssertEqual(store.setEnabled(false, for: OpenRouterAccount.defaultID), .updated)
        XCTAssertEqual(store.setEnabled(false, for: account.id), .rejectedLastEnabledAccount)
        XCTAssertEqual(store.removeAccount(id: account.id), .rejectedLastEnabledAccount)
        XCTAssertEqual(store.enabledAccounts.map(\.id), [account.id])
    }

    func testRemoveDeletesCustomButNeverTheDefaultSentinel() {
        let (store, _) = makeStore()
        let account = addKey(store, "Temp")
        XCTAssertTrue(store.removeAccount(id: account.id).isUpdated)
        XCTAssertNil(store.accounts.first { $0.id == account.id })

        XCTAssertEqual(store.removeAccount(id: OpenRouterAccount.defaultID), .unchanged)
        XCTAssertTrue(store.accounts.contains(where: \.isDefault))
    }

    func testOrderSurvivesReloadAndPrunesDeletedIDs() {
        let (store, defaults) = makeStore()
        let first = addKey(store, "First")
        let second = addKey(store, "Second")

        var reloaded = OpenRouterAccountStore(userDefaults: defaults, refreshConfigurationDirectory: nil)
        reloaded.moveAccounts(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        let reordered = OpenRouterAccountStore(userDefaults: defaults, refreshConfigurationDirectory: nil)
        XCTAssertEqual(
            reordered.accounts.map(\.id),
            [second.id, OpenRouterAccount.defaultID, first.id],
            "moving the last row to the front reorders the whole list"
        )

        reordered.removeAccount(id: second.id)
        let pruned = OpenRouterAccountStore(userDefaults: defaults, refreshConfigurationDirectory: nil)
        XCTAssertNil(pruned.accountOrder.first { $0 == second.id })
    }
}

private extension OpenRouterAccountMutationOutcome {
    var isUpdated: Bool { self == .updated }
}
