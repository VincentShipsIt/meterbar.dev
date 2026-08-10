import XCTest
@testable import MeterBar

/// Unit tests for the UserDefaults-backed manual and automatic conversion
/// modes, with locale, clock, and networking injected.
final class DisplayCurrencyStoreTests: XCTestCase {
    func testDefaultsToNoConversionWhenNothingHasBeenSaved() {
        withIsolatedDefaults { defaults in
            let store = DisplayCurrencyStore(userDefaults: defaults)

            XCTAssertNil(store.currency)
            XCTAssertTrue(store.isAutomatic)
        }
    }

    func testSetPersistsCodeRateAndAnEnteredAtTimestamp() {
        withIsolatedDefaults { defaults in
            let store = DisplayCurrencyStore(userDefaults: defaults)

            store.set(code: "eur", rate: 0.92)

            guard let currency = store.currency else {
                return XCTFail("Expected the manual currency to be saved")
            }
            XCTAssertEqual(currency.code, "EUR")
            XCTAssertEqual(currency.unitsPerUSD, 0.92, accuracy: 0.0001)
            XCTAssertEqual(currency.source, .manual)
            XCTAssertFalse(store.isAutomatic)
            XCTAssertLessThan(abs(currency.enteredAt.timeIntervalSinceNow), 5)

            let reloaded = DisplayCurrencyStore(userDefaults: defaults)
            XCTAssertEqual(reloaded.currency, currency)
        }
    }

    func testSetTrimsAndUppercasesTheCode() {
        withIsolatedDefaults { defaults in
            let store = DisplayCurrencyStore(userDefaults: defaults)

            store.set(code: "  jpy  ", rate: 150)

            XCTAssertEqual(store.currency?.code, "JPY")
        }
    }

    func testSetRejectsANonPositiveRateAndClearsAnyExistingConversion() {
        withIsolatedDefaults { defaults in
            let store = DisplayCurrencyStore(userDefaults: defaults)
            store.set(code: "EUR", rate: 0.92)

            store.set(code: "EUR", rate: 0)

            XCTAssertNil(store.currency)
            XCTAssertNil(DisplayCurrencyStore(userDefaults: defaults).currency)
        }
    }

    func testSetRejectsANonFiniteRateAndClearsAnyExistingConversion() {
        withIsolatedDefaults { defaults in
            let store = DisplayCurrencyStore(userDefaults: defaults)
            store.set(code: "EUR", rate: 0.92)

            // Infinity satisfies `rate > 0`, so without an explicit finite
            // check it would persist and turn every converted total into "inf".
            store.set(code: "EUR", rate: .infinity)

            XCTAssertNil(store.currency)
            XCTAssertNil(DisplayCurrencyStore(userDefaults: defaults).currency)
        }
    }

    func testLoadIgnoresAPersistedNonFiniteRate() {
        withIsolatedDefaults { defaults in
            defaults.set("EUR", forKey: StorageKeys.displayCurrencyCode)
            defaults.set(Double.infinity, forKey: StorageKeys.displayCurrencyRate)
            defaults.set(Date(), forKey: StorageKeys.displayCurrencyEnteredAt)

            XCTAssertNil(DisplayCurrencyStore(userDefaults: defaults).currency)
        }
    }

    func testSetRejectsAnEmptyOrBlankCode() {
        withIsolatedDefaults { defaults in
            let store = DisplayCurrencyStore(userDefaults: defaults)

            store.set(code: "   ", rate: 0.92)

            XCTAssertNil(store.currency)
        }
    }

    func testClearRemovesAPersistedConversion() {
        withIsolatedDefaults { defaults in
            let store = DisplayCurrencyStore(userDefaults: defaults)
            store.set(code: "EUR", rate: 0.92)

            store.clear()

            XCTAssertNil(store.currency)
            XCTAssertFalse(store.isAutomatic)
            XCTAssertNil(DisplayCurrencyStore(userDefaults: defaults).currency)
        }
    }

    func testExistingSavedRateMigratesAsManualWithoutAutomaticReplacement() {
        withIsolatedDefaults { defaults in
            defaults.set("EUR", forKey: StorageKeys.displayCurrencyCode)
            defaults.set(0.92, forKey: StorageKeys.displayCurrencyRate)
            defaults.set(Date(timeIntervalSince1970: 1_784_000_000), forKey: StorageKeys.displayCurrencyEnteredAt)

            let store = DisplayCurrencyStore(userDefaults: defaults)

            XCTAssertEqual(store.currency?.source, .manual)
            XCTAssertFalse(store.isAutomatic)
        }
    }

    func testAutomaticRefreshDetectsLocaleFetchesAndPersistsOfficialRate() async {
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
                localeCurrencyCode: { "eur" },
                now: { now }
            )

            await store.refreshAutomaticCurrency()

            XCTAssertEqual(requestedCodes, ["EUR"])
            XCTAssertEqual(store.currency?.code, "EUR")
            XCTAssertEqual(store.currency?.unitsPerUSD ?? 0, 0.8645, accuracy: 0.000_001)
            XCTAssertEqual(store.currency?.enteredAt, referenceDate)
            XCTAssertEqual(store.currency?.source, .europeanCentralBank)
            XCTAssertTrue(defaults.bool(forKey: StorageKeys.displayCurrencyAutomatic))

            let reloaded = DisplayCurrencyStore(userDefaults: defaults)
            XCTAssertEqual(reloaded.currency, store.currency)
            XCTAssertTrue(reloaded.isAutomatic)
        }
    }

    func testFreshAutomaticCacheDoesNotFetchAgain() async {
        await withIsolatedDefaults { defaults in
            let now = Date(timeIntervalSince1970: 1_786_000_000)
            var fetchCount = 0
            let store = DisplayCurrencyStore(
                userDefaults: defaults,
                fetchAutomaticRate: { code in
                    fetchCount += 1
                    return DisplayCurrencyRateQuote(code: code, unitsPerUSD: 0.86, referenceDate: now)
                },
                localeCurrencyCode: { "EUR" },
                now: { now }
            )

            await store.refreshAutomaticCurrency()
            await store.refreshAutomaticCurrency()

            XCTAssertEqual(fetchCount, 1)
        }
    }

    func testAutomaticFailureKeepsLastSavedRate() async {
        await withIsolatedDefaults { defaults in
            let store = DisplayCurrencyStore(
                userDefaults: defaults,
                fetchAutomaticRate: { _ in throw URLError(.notConnectedToInternet) },
                localeCurrencyCode: { "EUR" }
            )
            store.set(code: "EUR", rate: 0.91)
            let saved = store.currency
            store.setAutomaticEnabled(true)

            await store.refreshAutomaticCurrency(force: true)

            XCTAssertEqual(store.currency, saved)
            XCTAssertEqual(store.automaticRateError?.contains("last saved rate"), true)
        }
    }

    func testUSDAutomaticModeUsesIdentityWithoutNetwork() async {
        await withIsolatedDefaults { defaults in
            var didFetch = false
            let store = DisplayCurrencyStore(
                userDefaults: defaults,
                fetchAutomaticRate: { code in
                    didFetch = true
                    throw DisplayCurrencyRateError.unsupportedCurrency(code)
                },
                localeCurrencyCode: { "USD" }
            )

            await store.refreshAutomaticCurrency()

            XCTAssertFalse(didFetch)
            XCTAssertEqual(store.currency?.unitsPerUSD, 1)
            XCTAssertEqual(store.currency?.source, .system)
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
