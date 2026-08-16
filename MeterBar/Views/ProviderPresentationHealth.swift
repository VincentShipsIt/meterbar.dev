import Foundation

/// One provider/account card's connection health, separate from `QuotaBand`.
///
/// Quota severity stays a pure function of the cached percentages. This
/// projection answers whether those numbers are current, stale, or from a
/// failed refresh, so a 70%-left cache cannot be labelled Healthy.
enum ProviderPresentationHealth {
    /// Signed-in / access. `unprobed` is not a failure.
    enum Access: Equatable {
        case unprobed
        case signedIn
        case loginRequired
        case notConnected
    }

    /// Latest refresh for this card. `unprobed` is not a failure.
    enum RefreshOutcome: Equatable {
        case unprobed
        case success
        case transientFailure
        case sustainedOrParseFailure
    }

    /// Last observed fetch errors. Missing entries are unprobed, not failures.
    struct LastErrors {
        var cursor: ServiceError?
        var openRouter: ServiceError?
        var codexAccounts: [UUID: ServiceError] = [:]
        var grokAccounts: [UUID: ServiceError] = [:]
    }

    static var staleAfter: TimeInterval { ProviderParseHealthRecord.staleAfter }

    /// Maps access, refresh outcome, parse health, and cache freshness onto the
    /// card overlay. `nil` means the band may speak. No cache never fabricates
    /// stale or attention — empty/offline stays empty/offline.
    static func notice(
        access: Access,
        refresh: RefreshOutcome,
        lastUpdated: Date?,
        parseHealth: ProviderParseHealthRecord?,
        now: Date
    ) -> ProviderAuthNotice? {
        guard let lastUpdated else { return nil }

        switch access {
        case .loginRequired:
            return .loginRequired
        case .notConnected:
            return .notConnected
        case .unprobed, .signedIn:
            break
        }

        if refresh == .sustainedOrParseFailure
            || (refresh != .success && parseHealth?.isSustainedOrParseFailure == true) {
            return .attention("Refresh failed")
        }

        if refresh == .transientFailure {
            return .stale(since: lastUpdated)
        }

        if now.timeIntervalSince(lastUpdated) > staleAfter {
            return .stale(since: lastUpdated)
        }

        return nil
    }

    /// Live `lastError` wins when the process still has it. After relaunch that
    /// field is empty, so a persisted parse-health attempt newer than this
    /// card's cache is the failure. A cache as new as the attempt is evidence
    /// this account succeeded and must not inherit a sibling's failure.
    static func refreshOutcome(
        lastError: ServiceError?,
        parseHealth: ProviderParseHealthRecord?,
        lastUpdated: Date?
    ) -> RefreshOutcome {
        if lastError != nil {
            return parseHealth?.isSustainedOrParseFailure == true
                ? .sustainedOrParseFailure
                : .transientFailure
        }

        guard let lastUpdated else { return .unprobed }
        guard let parseHealth else { return .success }

        if lastUpdated >= parseHealth.lastAttempt {
            return .success
        }

        let attemptFailed = parseHealth.lastSuccess.map { parseHealth.lastAttempt > $0 }
            ?? (parseHealth.consecutiveFailures > 0)
        guard attemptFailed else { return .success }

        return parseHealth.isSustainedOrParseFailure
            ? .sustainedOrParseFailure
            : .transientFailure
    }

    static func access(
        probed: Bool?,
        lastError: ServiceError?,
        usesAPIKey: Bool
    ) -> Access {
        if probed == true { return .signedIn }
        if probed == false {
            return usesAPIKey ? .notConnected : .loginRequired
        }
        if case .notAuthenticated = lastError {
            return usesAPIKey ? .notConnected : .loginRequired
        }
        return .unprobed
    }
}
