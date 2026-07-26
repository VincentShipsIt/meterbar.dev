import Foundation

/// A user-supplied, presentation-only currency conversion for cost views and
/// the CLI (issue #270). MeterBar NEVER fetches a live exchange rate — the
/// rate is exactly what the user typed, and every converted figure must show
/// both the rate and the date it was entered so it can't be mistaken for a
/// live quote. Stored and exported cost data (JSON, daily usage, breakdowns)
/// always stays USD; this type only affects what is rendered on screen.
nonisolated public struct DisplayCurrency: Equatable, Sendable {
    /// Free-form currency code/label the user types (e.g. "EUR", "JPY",
    /// "credits"). Not validated against ISO 4217 or any live list — MeterBar
    /// has no way to look one up without a network call, which is explicitly
    /// out of scope for this feature.
    public let code: String
    /// User-supplied units of `code` per 1 USD. `convert` treats a
    /// non-positive rate as an identity fallback; the store that persists
    /// this value is responsible for rejecting one before it's saved.
    public let unitsPerUSD: Double
    /// When the user entered this rate — shown alongside every converted
    /// figure so it reads as a manual snapshot, never a live quote.
    public let enteredAt: Date

    public init(code: String, unitsPerUSD: Double, enteredAt: Date) {
        self.code = code
        self.unitsPerUSD = unitsPerUSD
        self.enteredAt = enteredAt
    }

    /// Converts a USD amount to `code`, rounded to 2 decimal places (the same
    /// precision `UsageFormat.cost` displays), half-away-from-zero — matching
    /// `Foundation`'s default `rounded()` behavior.
    public func convert(usd amount: Double) -> Double {
        guard unitsPerUSD > 0 else { return amount }
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

    /// Disclosure text shown next to every converted figure, e.g.
    /// "1 USD = 0.92 EUR, entered 2026-07-20" — the fixed pairing of rate and
    /// entry date that keeps a converted number from reading as a live quote.
    public var disclosureText: String {
        "1 USD = \(formattedRate) \(code), entered \(Self.enteredAtFormatter.string(from: enteredAt))"
    }

    /// Trims insignificant trailing zeros (e.g. `150` not `150.0000`,
    /// `0.92` not `0.9200`) while keeping enough precision for rates typed
    /// with more than two decimal places.
    private var formattedRate: String {
        String(format: "%.4g", unitsPerUSD)
    }

    /// Converted amount paired with the currency code, e.g. `"9.20 EUR"`.
    /// Shared by the CLI's text output and any SwiftUI presentation so the
    /// two never drift on rounding/format — always call this rather than
    /// formatting `convert(usd:)` ad hoc at each call site.
    public func formattedConverted(usd amount: Double) -> String {
        String(format: "%.2f", convert(usd: amount)) + " " + code
    }
}
