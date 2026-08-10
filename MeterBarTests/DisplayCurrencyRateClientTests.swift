import Foundation
@testable import MeterBar
import XCTest

final class DisplayCurrencyRateClientTests: XCTestCase {
    private let feed = Data(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01"
            xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
          <Cube>
            <Cube time="2026-08-08">
              <Cube currency="USD" rate="1.2000"/>
              <Cube currency="JPY" rate="150.0000"/>
              <Cube currency="GBP" rate="0.8400"/>
            </Cube>
          </Cube>
        </gesmes:Envelope>
        """.utf8
    )

    func testParsesEuroRateAsTheReciprocalOfUSDPerEuro() throws {
        let quote = try DisplayCurrencyRateClient.parse(feed, targetCode: "EUR")

        XCTAssertEqual(quote.code, "EUR")
        XCTAssertEqual(quote.unitsPerUSD, 1 / 1.2, accuracy: 0.000_001)
        XCTAssertEqual(day(quote.referenceDate), "2026-08-08")
    }

    func testConvertsAnotherEuroQuoteIntoUnitsPerUSD() throws {
        let quote = try DisplayCurrencyRateClient.parse(feed, targetCode: "jpy")

        XCTAssertEqual(quote.code, "JPY")
        XCTAssertEqual(quote.unitsPerUSD, 125, accuracy: 0.000_001)
    }

    func testUSDIsAnIdentityRate() throws {
        let quote = try DisplayCurrencyRateClient.parse(feed, targetCode: "USD")

        XCTAssertEqual(quote.unitsPerUSD, 1, accuracy: 0.000_001)
    }

    func testUnsupportedCurrencyFailsInsteadOfInventingARate() {
        XCTAssertThrowsError(try DisplayCurrencyRateClient.parse(feed, targetCode: "BTC")) { error in
            guard case DisplayCurrencyRateError.unsupportedCurrency("BTC") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testFetchUsesTheOfficialECBFeedAndRejectsHTTPFailure() async throws {
        var requestedURL: URL?
        let client = DisplayCurrencyRateClient { request in
            requestedURL = request.url
            let response = try XCTUnwrap(
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 503, httpVersion: nil, headerFields: nil)
            )
            return (Data(), response)
        }

        do {
            _ = try await client.fetchRate(for: "EUR")
            XCTFail("Expected the HTTP failure to be rejected")
        } catch DisplayCurrencyRateError.invalidResponse {
            // Expected.
        }

        XCTAssertEqual(
            requestedURL?.absoluteString,
            "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"
        )
    }

    private func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
