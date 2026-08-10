import XCTest
@testable import MeterBar

/// Unit tests for the presentation-only conversion model. These pin down the
/// rounding rule and source-aware disclosure text.
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

    private var referenceDateDayString: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
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

    func testAutomaticDisclosureNamesECBAndItsReferenceDate() {
        let currency = DisplayCurrency(
            code: "EUR",
            unitsPerUSD: 0.92,
            enteredAt: enteredAt,
            source: .europeanCentralBank
        )

        XCTAssertEqual(
            currency.disclosureText,
            "1 USD = 0.92 EUR, ECB reference rate \(referenceDateDayString)"
        )
    }

    func testSystemIdentityDisclosureNamesMacRegionSettings() {
        let currency = DisplayCurrency(
            code: "USD",
            unitsPerUSD: 1,
            enteredAt: enteredAt,
            source: .system
        )

        XCTAssertEqual(currency.disclosureText, "1 USD = 1 USD, from Mac region settings")
    }

    func testConvertTreatsANonFiniteRateAsAnIdentityFallback() {
        // `Double.infinity` and `.nan` both slip past a bare `rate > 0` check
        // (NaN fails it, infinity passes it), so a corrupted defaults value
        // must not be able to render every total as "inf".
        let infinite = DisplayCurrency(code: "EUR", unitsPerUSD: .infinity, enteredAt: enteredAt)
        let notANumber = DisplayCurrency(code: "EUR", unitsPerUSD: .nan, enteredAt: enteredAt)

        XCTAssertEqual(infinite.convert(usd: 10), 10, accuracy: 0.0001)
        XCTAssertEqual(notANumber.convert(usd: 10), 10, accuracy: 0.0001)
    }

    func testDisclosureTextTrimsTrailingZerosFromTheRate() {
        let currency = DisplayCurrency(code: "JPY", unitsPerUSD: 150, enteredAt: enteredAt)

        XCTAssertEqual(currency.disclosureText, "1 USD = 150 JPY, entered \(enteredAtDayString)")
    }

    func testDisclosureTextKeepsLargeRatesInPlainDecimalNotation() {
        // %g would render VND's ~24,000 as "2.4e+04" — unreadable as a rate.
        let currency = DisplayCurrency(code: "VND", unitsPerUSD: 24_000, enteredAt: enteredAt)

        XCTAssertEqual(currency.disclosureText, "1 USD = 24000 VND, entered \(enteredAtDayString)")
    }

    func testDisclosureTextKeepsSmallRatesInPlainDecimalNotation() {
        // …and %g would render 0.00008 as "8e-05" for the same reason.
        let currency = DisplayCurrency(code: "BTC", unitsPerUSD: 0.0001, enteredAt: enteredAt)

        XCTAssertEqual(currency.disclosureText, "1 USD = 0.0001 BTC, entered \(enteredAtDayString)")
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
