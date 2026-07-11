import Foundation

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

    private static let currencyNumber: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
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

    /// Full token count with thousands separators, e.g. `1,234,567`.
    public static func groupedTokens(_ value: Int) -> String {
        groupedInteger.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Currency string, e.g. `$12.34`.
    public static func cost(_ value: Double) -> String {
        "$\(currencyNumber.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value))"
    }

    /// Abbreviated relative time, e.g. `2h ago`, using a cached formatter.
    public static func relative(_ date: Date, to reference: Date = Date()) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: reference)
    }
}
