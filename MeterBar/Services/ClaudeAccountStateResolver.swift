import Foundation

/// Turns one account's refresh outcome into the state its card should show.
///
/// The service records what it observed while fetching (`serviceState`), but the
/// card also needs to know whether the refresh actually produced numbers and
/// whether an earlier reading survives in cache. A failed leg that falls back to
/// cached metrics is the case this exists for: the numbers are real but old, and
/// the card must say so instead of colouring a green band from them.
enum ClaudeAccountStateResolver {
    /// - Parameters:
    ///   - serviceState: what `ClaudeCodeLocalService` recorded for this account
    ///     on this pass, if anything.
    ///   - didSucceed: whether the fetch leg returned fresh metrics.
    ///   - failure: the error the leg threw, when it failed.
    ///   - cachedLastUpdated: timestamp of the reading the card will fall back
    ///     to, or nil when there is nothing cached.
    static func state(
        serviceState: ClaudeCodeAuthState?,
        didSucceed: Bool,
        failure: Error?,
        cachedLastUpdated: Date?
    ) -> ClaudeCodeAuthState {
        if didSucceed {
            // Fresh numbers landed, so the profile works. If the service never
            // attributed a source, "ready" is the honest neutral.
            return serviceState ?? .cliAvailable
        }

        switch serviceState {
        case .needsLogin, .unavailable:
            // Both outrank staleness: they explain why refreshing will keep
            // failing, which "your data is a bit old" would hide.
            return serviceState ?? .needsLogin
        default:
            break
        }

        if let cachedLastUpdated {
            return .stale(since: cachedLastUpdated)
        }

        // A cold failure has nothing to call stale.
        if let serviceState {
            return serviceState
        }
        return .error(failure?.localizedDescription ?? "Refresh failed")
    }
}
