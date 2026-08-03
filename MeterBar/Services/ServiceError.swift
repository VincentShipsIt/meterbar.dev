import Foundation

/// Shared error type for all provider usage services.
public enum ServiceError: LocalizedError, Sendable {
    case notAuthenticated
    case invalidURL
    case apiError(String)
    /// A response MeterBar could not read. The associated value carries an
    /// authored explanation when the failing service knows one worth showing
    /// (see `ClaudeCodeParseFailure`); `nil` keeps the generic message. It is
    /// never provider output — the sanitizers drop anything unrecognized before
    /// it reaches a view.
    case parsingError(String?)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated. Sign in to the provider's CLI and refresh."
        case .invalidURL:
            return "Invalid URL"
        case .apiError(let message):
            return message
        case .parsingError(let detail):
            return detail ?? "Failed to parse response"
        }
    }
}
