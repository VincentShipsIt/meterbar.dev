import Foundation

/// One official reference-rate snapshot converted into the app's
/// "target-currency units per 1 USD" representation.
nonisolated struct DisplayCurrencyRateQuote: Equatable, Sendable {
    let code: String
    let unitsPerUSD: Double
    let referenceDate: Date
}

nonisolated enum DisplayCurrencyRateError: LocalizedError {
    case invalidResponse
    case invalidPayload
    case unsupportedCurrency(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The exchange-rate service returned an invalid response."
        case .invalidPayload:
            "The exchange-rate service returned unreadable data."
        case .unsupportedCurrency(let code):
            "The ECB does not publish a reference rate for \(code)."
        }
    }
}

/// Fetches the European Central Bank's keyless daily reference-rate feed.
///
/// The ECB quotes every published currency as units per EUR. MeterBar stores
/// units per USD, so a target rate is `targetPerEUR / usdPerEUR`. The service
/// is deliberately stateless; `DisplayCurrencyStore` owns refresh cadence and
/// the last-known-good offline cache.
nonisolated struct DisplayCurrencyRateClient {
    typealias FetchData = (URLRequest) async throws -> (Data, URLResponse)

    private static let feedURL = URL(
        string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"
    )!

    private let fetchData: FetchData

    init(fetchData: FetchData? = nil) {
        self.fetchData = fetchData ?? { request in
            try await ServiceSupport.data(for: request)
        }
    }

    func fetchRate(for rawCode: String) async throws -> DisplayCurrencyRateQuote {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else {
            throw DisplayCurrencyRateError.unsupportedCurrency(rawCode)
        }

        var request = URLRequest(url: Self.feedURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await fetchData(request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw DisplayCurrencyRateError.invalidResponse
        }
        return try Self.parse(data, targetCode: code)
    }

    static func parse(_ data: Data, targetCode: String) throws -> DisplayCurrencyRateQuote {
        let delegate = ECBReferenceRateParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let rawReferenceDate = delegate.referenceDate else {
            throw DisplayCurrencyRateError.invalidPayload
        }

        let code = targetCode.uppercased()
        guard let usdPerEUR = delegate.ratesPerEUR["USD"], usdPerEUR > 0 else {
            throw DisplayCurrencyRateError.invalidPayload
        }

        let targetPerEUR: Double
        if code == "EUR" {
            targetPerEUR = 1
        } else if code == "USD" {
            targetPerEUR = usdPerEUR
        } else if let publishedRate = delegate.ratesPerEUR[code], publishedRate > 0 {
            targetPerEUR = publishedRate
        } else {
            throw DisplayCurrencyRateError.unsupportedCurrency(code)
        }

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy-MM-dd"
        guard let referenceDate = dateFormatter.date(from: rawReferenceDate) else {
            throw DisplayCurrencyRateError.invalidPayload
        }

        return DisplayCurrencyRateQuote(
            code: code,
            unitsPerUSD: targetPerEUR / usdPerEUR,
            referenceDate: referenceDate
        )
    }
}

nonisolated private final class ECBReferenceRateParser: NSObject, XMLParserDelegate {
    private(set) var referenceDate: String?
    private(set) var ratesPerEUR: [String: Double] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if let time = attributeDict["time"] {
            referenceDate = time
        }
        guard let currency = attributeDict["currency"],
              let rawRate = attributeDict["rate"],
              let rate = Double(rawRate),
              rate > 0,
              rate.isFinite else {
            return
        }
        ratesPerEUR[currency.uppercased()] = rate
    }
}
