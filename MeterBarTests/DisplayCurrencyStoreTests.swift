import XCTest
@testable import MeterBar

/// Unit tests for `DisplayCurrencyStore` — the `UserDefaults`-backed
/// persistence layer for the presentation-only currency conversion behind
/// issue #270, modeled on `ProviderVisibilityStore`'s test conventions.
final class DisplayCurrencyStoreTests: XCTestCase {
    func testDefaultsToNoConversionWhenNothingHasBeenSaved() {
        withIsolatedDefaults { defaults in
            let store = DisplayCurrencyStore(userDefaults: defaults)

            XCTAssertNil(store.currency)
        }
    }

    func testSetPersistsCodeRateAndAnEnteredAtTimestamp() {
        withIsolatedDefaults { defaults in
            let store = DisplayCurrencyStore(userDefaults: defaults)

            store.set(code: "eur", rate: 0.92)

            let currency = try! XCTUnwrap(store.currency)
            XCTAssertEqual(currency.code, "EUR")
            XCTAssertEqual(currency.unitsPerUSD, 0.92, accuracy: 0.0001)
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
            XCTAssertNil(DisplayCurrencyStore(userDefaults: defaults).currency)
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
}
