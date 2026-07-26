import XCTest
@testable import MeterBar

/// Unit tests for `DisplayCurrency` — the presentation-only, user-supplied
/// conversion behind issue #270. MeterBar never fetches a live exchange rate;
/// these tests pin down the rounding rule and the disclosure text that keeps
/// a converted figure from being mistaken for a live quote.
final class DisplayCurrencyTests: XCTestCase {
    private let enteredAt = Date(timeIntervalSince1970: 1_784_000_000)

    /// Mirrors `DisplayCurrency`'s own day formatting so assertions don't
    /// hardcode a calendar day that shifts with the test runner's time zone.
    private var enteredAtDayString: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: enteredAt)
    }

    func testConvertMultipliesUSDByTheUserSuppliedRate() {
        let currency = DisplayCurrency(code: "EUR", unitsPerUSD: 0.92, enteredAt: enteredAt)

        XCTAssertEqual(currency.convert(usd: 10), 9.2, accuracy: 0.0001)
    }

    func testConvertRoundsToTwoDecimalPlacesHalfAwayFromZero() {
        // 1.005 * 100 = 100.49999999999999 in double arithmetic; picking a rate
        // that lands exactly on a half-cent (1.115 -> 111.5 cents) pins down
        // that the rule is round-half-away-from-zero, not floor/truncation.
        let currency = DisplayCurrency(code: "USD", unitsPerUSD: 1.115, enteredAt: enteredAt)

        XCTAssertEqual(currency.convert(usd: 1), 1.12, accuracy: 0.0001)
    }

    func testConvertRoundsDownWhenBelowTheHalfCent() {
        let currency = DisplayCurrency(code: "USD", unitsPerUSD: 1.114, enteredAt: enteredAt)

        XCTAssertEqual(currency.convert(usd: 1), 1.11, accuracy: 0.0001)
    }

    func testConvertAtAnIdentityRateReturnsTheSameUSDAmount() {
        let currency = DisplayCurrency(code: "USD", unitsPerUSD: 1, enteredAt: enteredAt)

        XCTAssertEqual(currency.convert(usd: 42.5), 42.5, accuracy: 0.0001)
    }

    func testConvertTreatsANonPositiveRateAsAnIdentityFallback() {
        // The store is responsible for rejecting non-positive rates before
        // persisting one, but `convert` stays defensive so a corrupted/edited
        // defaults value can never silently zero out or invert a cost figure.
        let zero = DisplayCurrency(code: "EUR", unitsPerUSD: 0, enteredAt: enteredAt)
        let negative = DisplayCurrency(code: "EUR", unitsPerUSD: -1, enteredAt: enteredAt)

        XCTAssertEqual(zero.convert(usd: 10), 10, accuracy: 0.0001)
        XCTAssertEqual(negative.convert(usd: 10), 10, accuracy: 0.0001)
    }

    func testDisclosureTextPairsTheRateWithTheEnteredDateSoItReadsAsAManualSnapshot() {
        let currency = DisplayCurrency(code: "EUR", unitsPerUSD: 0.92, enteredAt: enteredAt)

        XCTAssertEqual(currency.disclosureText, "1 USD = 0.92 EUR, entered \(enteredAtDayString)")
    }

    func testDisclosureTextTrimsTrailingZerosFromTheRate() {
        let currency = DisplayCurrency(code: "JPY", unitsPerUSD: 150, enteredAt: enteredAt)

        XCTAssertEqual(currency.disclosureText, "1 USD = 150 JPY, entered \(enteredAtDayString)")
    }

    func testFormattedConvertedPairsTheRoundedAmountWithTheCode() {
        let currency = DisplayCurrency(code: "EUR", unitsPerUSD: 0.92, enteredAt: enteredAt)

        XCTAssertEqual(currency.formattedConverted(usd: 10), "9.20 EUR")
    }

    func testFormattedConvertedAlwaysShowsTwoDecimalPlaces() {
        let currency = DisplayCurrency(code: "JPY", unitsPerUSD: 150, enteredAt: enteredAt)

        XCTAssertEqual(currency.formattedConverted(usd: 1), "150.00 JPY")
    }
}
