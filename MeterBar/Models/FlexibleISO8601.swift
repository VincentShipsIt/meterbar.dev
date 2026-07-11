import Foundation

/// Cached ISO8601 parsers with a fractional-seconds -> plain fallback.
///
/// Shared by the hot scan paths (CostTracker parses tens of thousands of log
/// lines) and CursorLocalService, which previously each maintained their own
/// identical formatter pair. `ISO8601DateFormatter` is thread-safe to share.
nonisolated enum FlexibleISO8601 {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }
}
