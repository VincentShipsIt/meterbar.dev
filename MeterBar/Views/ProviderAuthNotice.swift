import Foundation

/// A card-level overlay for auth/staleness, layered *on top of* `QuotaBand`.
///
/// `QuotaBand` stays a pure function of the percentages — that is what makes it
/// testable and shared — but a percentage cannot know that the reading behind it
/// failed to refresh. Without this, a logged-out profile's last-known 12% still
/// renders as a green "Healthy" band. The notice wins wherever the card shows a
/// status word or colour; the band itself keeps describing the numbers.
enum ProviderAuthNotice: Equatable {
    case loginRequired
    case stale(since: Date)
    case attention(String)
    case notConnected

    var shortLabel: String {
        switch self {
        case .loginRequired:
            return "Login required"
        case .stale:
            return "Stale"
        case .attention:
            return "Needs attention"
        case .notConnected:
            return "Not connected"
        }
    }

    /// `nil` for every healthy state, so a working card is untouched.
    static func forState(_ state: ClaudeCodeAuthState?) -> ProviderAuthNotice? {
        switch state {
        case .none, .connected, .cliAvailable:
            return nil
        case .needsLogin:
            return .loginRequired
        case let .stale(since):
            return .stale(since: since)
        case let .error(message):
            return .attention(message)
        case .unavailable:
            return .notConnected
        }
    }
}
