import Foundation
import MeterBarShared

/// Shared, cached formatting helpers.
///
/// Centralizes the compact token formatter (previously duplicated in four
/// places — one of which silently dropped the billions tier), grouped integer
/// formatting, currency formatting, and a cached `RelativeDateTimeFormatter`.
/// The formatters are created once and reused so hot UI/scan paths don't
/// reallocate a `NumberFormatter`/`RelativeDateTimeFormatter` on every call.
nonisolated public enum UsageFormat {
    private static let groupedInteger: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// Compact token count, e.g. `1.2K`, `3.4M`, `5.6B`.
    public static func tokens(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    /// Compact token count from a `Double` total, for figures built in the
    /// non-saturating domain (`TokenComposition`, the Usage page). Clamps to the
    /// `Int` range rather than trapping on the conversion, so a total past what
    /// `Int` can hold reads as the largest count `tokens(_:)` can format.
    static func compactTokens(_ value: Double) -> String {
        tokens(clampedTokenCount(value))
    }

    /// `value` as an `Int` token count: negative and non-finite values read as
    /// zero, and anything at or past `Int.max` saturates to it.
    static func clampedTokenCount(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        // `Double(Int.max)` rounds *up* to 2^63, which `Int(_:)` traps on.
        guard value < Double(Int.max) else { return Int.max }
        return Int(value)
    }

    /// Full token count with thousands separators, e.g. `1,234,567`.
    public static func groupedTokens(_ value: Int) -> String {
        groupedInteger.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Currency string, e.g. `$12.34`.
    public static func cost(_ value: Double) -> String {
        UsageAmountFormat.currency(value)
    }

    /// Abbreviated relative time, e.g. `2h ago`, using a cached formatter.
    public static func relative(_ date: Date, to reference: Date = Date()) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: reference)
    }
}
