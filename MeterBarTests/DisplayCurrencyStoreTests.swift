import XCTest
@testable import MeterBar

/// Unit tests for the UserDefaults-backed USD/EUR choice, with clock and
/// networking injected so no test depends on the live ECB feed.
final class DisplayCurrencyStoreTests: XCTestCase {
    func testDefaultsToUSDWithNoConversion() {
        withIsolatedDefaults { defaults in
            let store = DisplayCurrencyStore(userDefaults: defaults)

            XCTAssertEqual(store.selection, .usd)
            XCTAssertNil(store.currency)
            XCTAssertEqual(defaults.string(forKey: StorageKeys.displayCurrencySelection), "USD")
        }
    }

    func testSelectingEURFetchesAndPersistsOfficialRate() async {
        await withIsolatedDefaults { defaults in
            let now = Date(timeIntervalSince1970: 1_786_000_000)
            let referenceDate = Date(timeIntervalSince1970: 1_785_888_000)
            var requestedCodes: [String] = []
            let store = DisplayCurrencyStore(
                userDefaults: defaults,
                fetchAutomaticRate: { code in
                    requestedCodes.append(code)
                    return DisplayCurrencyRateQuote(
                        code: code,
                        unitsPerUSD: 0.8645,
                        referenceDate: referenceDate
                    )
                },
                now: { now }
            )

            store.setSelection(.eur)
            await store.refreshAutomaticCurrency()

            XCTAssertEqual(requestedCodes, ["EUR"])
            XCTAssertEqual(store.selection, .eur)
            XCTAssertEqual(store.currency?.code, "EUR")
            XCTAssertEqual(store.currency?.unitsPerUSD ?? 0, 0.8645, accuracy: 0.000_001)
            XCTAssertEqual(store.currency?.enteredAt, referenceDate)
            XCTAssertEqual(store.currency?.source, .europeanCentralBank)
            XCTAssertEqual(defaults.string(forKey: StorageKeys.displayCurrencySelection), "EUR")

            let reloaded = DisplayCurrencyStore(userDefaults: defaults)
            XCTAssertEqual(reloaded.selection, .eur)
            XCTAssertEqual(reloaded.currency, store.currency)
        }
    }

    func testSelectingUSDClearsConversionAndDoesNotFetch() async {
        await withIsolatedDefaults { defaults in
            var fetchCount = 0
            let store = DisplayCurrencyStore(
                userDefaults: defaults,
                fetchAutomaticRate: { code in
                    fetchCount += 1
                    return DisplayCurrencyRateQuote(code: code, unitsPerUSD: 0.86, referenceDate: Date())
                }
            )
            store.setSelection(.eur)
            await store.refreshAutomaticCurrency()
            XCTAssertNotNil(store.currency)

            store.setSelection(.usd)
            await store.refreshAutomaticCurrency(force: true)

            XCTAssertEqual(fetchCount, 1)
            XCTAssertEqual(store.selection, .usd)
            XCTAssertNil(store.currency)
            XCTAssertNil(defaults.string(forKey: StorageKeys.displayCurrencyCode))
        }
    }

    func testLegacyEURRateMigratesToUSDDefault() {
        withIsolatedDefaults { defaults in
            defaults.set("EUR", forKey: StorageKeys.displayCurrencyCode)
            defaults.set(0.92, forKey: StorageKeys.displayCurrencyRate)
            defaults.set(Date(timeIntervalSince1970: 1_784_000_000), forKey: StorageKeys.displayCurrencyEnteredAt)

            let store = DisplayCurrencyStore(userDefaults: defaults)

            XCTAssertEqual(store.selection, .usd)
            XCTAssertNil(store.currency)
        }
    }

    func testLegacyNonEURRateMigratesToUSDWithoutConversion() {
        withIsolatedDefaults { defaults in
            defaults.set("GBP", forKey: StorageKeys.displayCurrencyCode)
            defaults.set(0.78, forKey: StorageKeys.displayCurrencyRate)
            defaults.set(Date(timeIntervalSince1970: 1_784_000_000), forKey: StorageKeys.displayCurrencyEnteredAt)

            let store = DisplayCurrencyStore(userDefaults: defaults)

            XCTAssertEqual(store.selection, .usd)
            XCTAssertNil(store.currency)
        }
    }

    func testFreshEURCacheDoesNotFetchAgain() async {
        await withIsolatedDefaults { defaults in
            let now = Date(timeIntervalSince1970: 1_786_000_000)
            var fetchCount = 0
            let store = DisplayCurrencyStore(
                userDefaults: defaults,
                fetchAutomaticRate: { code in
                    fetchCount += 1
                    return DisplayCurrencyRateQuote(code: code, unitsPerUSD: 0.86, referenceDate: now)
                },
                now: { now }
            )

            store.setSelection(.eur)
            await store.refreshAutomaticCurrency()
            await store.refreshAutomaticCurrency()

            XCTAssertEqual(fetchCount, 1)
        }
    }

    func testEURRefreshFailureKeepsLastSavedRate() async {
        await withIsolatedDefaults { defaults in
            let now = Date(timeIntervalSince1970: 1_786_000_000)
            var shouldFail = false
            let store = DisplayCurrencyStore(
                userDefaults: defaults,
                fetchAutomaticRate: { code in
                    if shouldFail { throw URLError(.notConnectedToInternet) }
                    return DisplayCurrencyRateQuote(code: code, unitsPerUSD: 0.91, referenceDate: now)
                },
                now: { now }
            )
            store.setSelection(.eur)
            await store.refreshAutomaticCurrency()
            let saved = store.currency
            shouldFail = true

            await store.refreshAutomaticCurrency(force: true)

            XCTAssertEqual(store.currency, saved)
            XCTAssertEqual(store.automaticRateError?.contains("last saved rate"), true)
        }
    }

    func testSwitchingToUSDDuringFetchDoesNotRestoreEUR() async {
        await withIsolatedDefaults { defaults in
            let fetchStarted = expectation(description: "EUR fetch started")
            let store = DisplayCurrencyStore(
                userDefaults: defaults,
                fetchAutomaticRate: { code in
                    fetchStarted.fulfill()
                    try await Task.sleep(for: .milliseconds(50))
                    return DisplayCurrencyRateQuote(code: code, unitsPerUSD: 0.9, referenceDate: Date())
                }
            )
            store.setSelection(.eur)

            let refresh = Task { await store.refreshAutomaticCurrency() }
            await fulfillment(of: [fetchStarted], timeout: 1)
            store.setSelection(.usd)
            await refresh.value

            XCTAssertEqual(store.selection, .usd)
            XCTAssertNil(store.currency)
        }
    }

    func testLoadIgnoresPersistedNonFiniteEURRate() {
        withIsolatedDefaults { defaults in
            defaults.set("EUR", forKey: StorageKeys.displayCurrencySelection)
            defaults.set("EUR", forKey: StorageKeys.displayCurrencyCode)
            defaults.set(Double.infinity, forKey: StorageKeys.displayCurrencyRate)
            defaults.set(Date(), forKey: StorageKeys.displayCurrencyEnteredAt)

            let store = DisplayCurrencyStore(userDefaults: defaults)

            XCTAssertEqual(store.selection, .eur)
            XCTAssertNil(store.currency)
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "DisplayCurrencyStoreTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) async -> Void) async {
        let suiteName = "DisplayCurrencyStoreTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        await body(defaults)
    }
}
