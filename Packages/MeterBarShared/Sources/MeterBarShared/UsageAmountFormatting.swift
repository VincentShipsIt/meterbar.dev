import Foundation

/// Stable money formatting shared by the app, widget, CLI, and provider-detail copy.
public enum UsageAmountFormat {
    private static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    /// Formats USD with its symbol and other currencies with their ISO code.
    public static func currency(_ amount: Double, code: String? = "USD") -> String {
        let normalized = (code ?? "USD").uppercased()
        let number = decimal.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
        return normalized == "USD" ? "$\(number)" : "\(number) \(normalized)"
    }
}

/// Credit counts from Codex. Whole numbers stay whole (`62,317`); a fractional
/// balance keeps at most two digits (`12.5`, `2,995.45`). This is not money.
public enum CreditQuantityFormat {
    private static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    public static func grouped(_ amount: Double) -> String {
        guard amount.isFinite else { return "0" }
        return decimal.string(from: NSNumber(value: amount)) ?? "0"
    }
}
