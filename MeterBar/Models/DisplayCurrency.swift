import Foundation

nonisolated enum DisplayCurrencySelection: String, CaseIterable, Identifiable, Sendable {
    case usd = "USD"
    case eur = "EUR"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usd: "USD — US Dollar"
        case .eur: "EUR — Euro"
        }
    }
}

nonisolated public enum DisplayCurrencySource: String, Equatable, Sendable {
    case manual
    case europeanCentralBank = "ecb"
}

/// A presentation-only currency conversion for cost views and the CLI.
/// Stored and exported cost data (JSON, daily usage, breakdowns) always stays
/// USD; this type only affects what is rendered on screen. App-generated
/// conversions carry their official reference date, while CLI conversions
/// remain explicit manual snapshots.
nonisolated public struct DisplayCurrency: Equatable, Sendable {
    /// ISO currency code for automatic rates, or the user's free-form label
    /// for a manual conversion.
    public let code: String
    /// Units of `code` per 1 USD. `convert` treats a non-positive rate as an
    /// identity fallback; the store rejects one before it is saved.
    public let unitsPerUSD: Double
    /// Manual entry time or the official reference date for an automatic rate.
    public let enteredAt: Date
    public let source: DisplayCurrencySource

    public init(
        code: String,
        unitsPerUSD: Double,
        enteredAt: Date,
        source: DisplayCurrencySource = .manual
    ) {
        self.code = code
        self.unitsPerUSD = unitsPerUSD
        self.enteredAt = enteredAt
        self.source = source
    }

    /// Converts a USD amount to `code`, rounded to 2 decimal places (the same
    /// precision `UsageFormat.cost` displays), half-away-from-zero — matching
    /// `Foundation`'s default `rounded()` behavior.
    public func convert(usd amount: Double) -> Double {
        guard unitsPerUSD > 0, unitsPerUSD.isFinite else { return amount }
        return (amount * unitsPerUSD * 100).rounded() / 100
    }

    /// Same stable, locale-independent day format used by `TokenCost`'s
    /// day-keyed identifiers, reused here so the disclosure date is
    /// unambiguous rather than a locale-dependent medium date style.
    private static let enteredAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// ECB dates are calendar dates, parsed at midnight UTC. Formatting them
    /// in a negative local offset would otherwise display the previous day.
    private static let referenceDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Disclosure text shown next to every converted figure. Automatic quotes
    /// name their source and reference day; manual snapshots retain the entry
    /// date so neither can be mistaken for a transaction-grade live quote.
    public var disclosureText: String {
        switch source {
        case .manual:
            let day = Self.enteredAtFormatter.string(from: enteredAt)
            return "1 USD = \(formattedRate) \(code), entered \(day)"
        case .europeanCentralBank:
            let day = Self.referenceDateFormatter.string(from: enteredAt)
            return "1 USD = \(formattedRate) \(code), ECB reference rate \(day)"
        }
    }

    /// Trims insignificant trailing zeros (e.g. `150` not `150.0000`,
    /// `0.92` not `0.9200`) while keeping enough precision for rates typed
    /// with more than two decimal places.
    ///
    /// Deliberately not `%g`: that switches to scientific notation once the
    /// exponent reaches the precision, so a legitimate rate like VND's
    /// ~24,000 would render as "2.4e+04" in the disclosure line. Fixed
    /// notation with the trailing zeros stripped keeps every rate readable.
    private var formattedRate: String {
        var text = String(format: "%.4f", unitsPerUSD)
        guard text.contains(".") else { return text }
        while text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }

    /// Converted amount paired with the currency code, e.g. `"9.20 EUR"`.
    /// Shared by the CLI's text output and any SwiftUI presentation so the
    /// two never drift on rounding/format — always call this rather than
    /// formatting `convert(usd:)` ad hoc at each call site.
    public func formattedConverted(usd amount: Double) -> String {
        String(format: "%.2f", convert(usd: amount)) + " " + code
    }
}
