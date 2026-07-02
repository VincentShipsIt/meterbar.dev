import Foundation

/// Shared error type for all provider usage services.
enum ServiceError: LocalizedError {
    case notAuthenticated
    case invalidURL
    case apiError(String)
    case parsingError

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated. Sign in to the provider's CLI and refresh."
        case .invalidURL:
            return "Invalid URL"
        case .apiError(let message):
            return message
        case .parsingError:
            return "Failed to parse response"
        }
    }
}
