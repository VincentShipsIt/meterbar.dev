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

// MARK: - Aggregate error lifecycle

/// Boxes the stub network's failure state so a test can flip one key between
/// failing and healthy across polls without rebuilding the service.
private final class FailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = true

    var isFailing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failing
    }

    func heal() {
        lock.lock()
        defer { lock.unlock() }
        failing = false
    }
}

/// `lastError` is documented as clearing only when every managed key is
/// healthy — one key's failure must survive its siblings' successful polls
/// and key edits until that key itself heals or leaves.
final class OpenRouterAggregateErrorTests: XCTestCase {
    private func makeKeychain(_ suffix: String) -> KeychainManager {
        KeychainManager(
            backend: SeededKeychainBackend(),
            currentService: "test.openrouter.aggregate.\(suffix)"
        )
    }

    /// Requests authenticated with `sk-or-v1-bad` fail while the switch is
    /// failing; every other key gets healthy fixture responses.
    private func makeService(
        keychain: KeychainManager,
        badKeyFails failureSwitch: FailureSwitch
    ) -> OpenRouterService {
        OpenRouterService(keychain: keychain) { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-v1-bad",
               failureSwitch.isFailing {
                throw ServiceError.apiError("Key disabled")
            }
            switch request.url?.path {
            case "/api/v1/credits":
                return Data(#"{"data":{"total_credits":100,"total_usage":25}}"#.utf8)
            case "/api/v1/key":
                return Data(#"{"data":{"limit":null,"limit_reset":null,"usage":27.5,"usage_daily":1.25}}"#.utf8)
            default:
                throw ServiceError.invalidURL
            }
        }
    }

    private func pollExpectingFailure(
        _ service: OpenRouterService,
        account: OpenRouterAccount,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await service.fetchUsageMetrics(account: account)
            XCTFail("the disabled key's poll must fail", file: file, line: line)
        } catch {}
    }

    func testSiblingSuccessLeavesAFailingKeysAggregateErrorInPlace() async throws {
        let keychain = makeKeychain("sibling")
        let failure = FailureSwitch()
        let service = makeService(keychain: keychain, badKeyFails: failure)
        let work = OpenRouterAccount(id: UUID(), name: "Work")
        XCTAssertTrue(service.saveAPIKey("sk-or-v1-good", for: OpenRouterAccount.defaultID))
        XCTAssertTrue(service.saveAPIKey("sk-or-v1-bad", for: work.id))

        await pollExpectingFailure(service, account: work)
        XCTAssertNotNil(service.lastError)
        XCTAssertNotNil(service.accountLastErrors[work.id])

        _ = try await service.fetchUsageMetrics(account: .defaultAccount)
        XCTAssertNotNil(
            service.lastError,
            "a sibling's healthy poll must not hide the failing key from diagnostics"
        )

        failure.heal()
        _ = try await service.fetchUsageMetrics(account: work)
        XCTAssertNil(service.lastError, "once every key is healthy the aggregate clears")
        XCTAssertNil(service.accountLastErrors[work.id])
    }

    func testRemovingTheOnlyFailingKeyClearsTheAggregateError() async {
        let keychain = makeKeychain("remove")
        let service = makeService(keychain: keychain, badKeyFails: FailureSwitch())
        let work = OpenRouterAccount(id: UUID(), name: "Work")
        XCTAssertTrue(service.saveAPIKey("sk-or-v1-bad", for: work.id))

        await pollExpectingFailure(service, account: work)
        XCTAssertNotNil(service.lastError)

        XCTAssertTrue(service.removeAPIKey(for: work.id))
        XCTAssertNil(service.lastError, "no managed key is failing once the failed key leaves")
    }

    func testSavingOneKeyKeepsAnotherKeysFailureOnTheAggregate() async {
        let keychain = makeKeychain("save")
        let service = makeService(keychain: keychain, badKeyFails: FailureSwitch())
        let work = OpenRouterAccount(id: UUID(), name: "Work")
        XCTAssertTrue(service.saveAPIKey("sk-or-v1-bad", for: work.id))

        await pollExpectingFailure(service, account: work)
        XCTAssertNotNil(service.lastError)

        XCTAssertTrue(service.saveAPIKey("sk-or-v1-new", for: OpenRouterAccount.defaultID))
        XCTAssertNotNil(
            service.lastError,
            "adding an unrelated key must not hide the failing key from diagnostics"
        )

        // Re-entering the failing account's own key is the user fixing it.
        XCTAssertTrue(service.saveAPIKey("sk-or-v1-fixed", for: work.id))
        XCTAssertNil(service.lastError)
    }
}

// MARK: - Off-main fetch regression

/// Regression for the 1.8.37 launch SIGSEGV (#480): the two `async let` legs
/// through the *stored* `fetchData` closure crossed a reabstraction-thunk
/// actor hop as main-actor jobs. Network + decode must run detached — the
/// stored closure must never execute on the main thread even when the poll is
/// awaited from the main actor.
final class OpenRouterOffMainFetchTests: XCTestCase {
    @MainActor
    func testFetchUsageMetricsRunsStoredFetchClosureOffMainThread() async throws {
        nonisolated final class ThreadRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var sawMainThread = false
            private var callCount = 0
            func record() {
                lock.lock()
                defer { lock.unlock() }
                if Thread.isMainThread { sawMainThread = true }
                callCount += 1
            }
            var wasCalledOnMainThread: Bool {
                lock.lock()
                defer { lock.unlock() }
                return sawMainThread
            }
            var wasCalled: Bool {
                lock.lock()
                defer { lock.unlock() }
                return callCount > 0
            }
        }

        let recorder = ThreadRecorder()
        let keychain = KeychainManager(
            backend: SeededKeychainBackend(),
            currentService: "test.openrouter.offmain"
        )
        let service = OpenRouterService(keychain: keychain) { request in
            recorder.record()
            switch request.url?.path {
            case "/api/v1/credits":
                return Data(#"{"data":{"total_credits":100,"total_usage":25}}"#.utf8)
            case "/api/v1/key":
                return Data(#"{"data":{"limit":null,"limit_reset":null,"usage":27.5,"usage_daily":1.25}}"#.utf8)
            default:
                throw ServiceError.invalidURL
            }
        }
        XCTAssertTrue(service.saveAPIKey("sk-or-v1-test", for: OpenRouterAccount.defaultID))

        let metrics = try await service.fetchUsageMetrics(account: .defaultAccount)

        XCTAssertEqual(metrics.service, .openRouter)
        XCTAssertTrue(recorder.wasCalled)
        XCTAssertFalse(
            recorder.wasCalledOnMainThread,
            "the stored fetch closure must never run as a main-actor job"
        )
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

        let reloaded = OpenRouterAccountStore(userDefaults: defaults, refreshConfigurationDirectory: nil)
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
