import Foundation

/// The closed set of ways a Grok Build refresh can fail, together with the exact
/// user-facing message each one produces.
///
/// Grok is the only provider MeterBar reads by driving a subprocess, so its
/// failures are transport failures ("the agent never started", "the agent is too
/// old to answer") that a generic "API error" cannot give useful advice for.
/// Readiness needs to turn each one into a specific recovery step, and the only
/// safe way to carry that across the `ServiceError` boundary is a fixed string.
///
/// Every `message` is a **constant** — no interpolation, ever. That is what makes
/// it safe for `ProviderReadinessInspector.sanitize` to pass these through
/// verbatim into a pasteable Diagnostics report: a value that cannot be built
/// from provider output cannot carry a token, an account id, or a response body.
public enum GrokRefreshFailure: String, Sendable, Equatable, CaseIterable {
    /// No usable cached login — the agent refused to authenticate.
    case notSignedIn
    /// The `grok` binary could not be spawned at all.
    case agentStartFailed
    /// The agent started but never answered within the request budget.
    case agentTimedOut
    /// The agent answered with something MeterBar could not decode.
    case unparseableResponse
    /// The agent does not implement the billing method (predates it).
    case unsupportedVersion
    /// The agent failed the request for a reason it did not qualify further.
    case requestFailed

    /// The sanitized text that reaches Diagnostics and `meterbar doctor`.
    ///
    /// `notSignedIn` and `unparseableResponse` deliberately reuse the strings
    /// `sanitize` already produces for `.notAuthenticated` and `.parsingError`,
    /// so the round-trip through `ServiceError` stays lossless.
    public var message: String {
        switch self {
        case .notSignedIn: return "Not authenticated"
        case .agentStartFailed: return "Could not start the Grok Build agent"
        case .agentTimedOut: return "Grok Build agent did not respond in time"
        case .unparseableResponse: return "Could not parse the provider response"
        case .unsupportedVersion: return "Grok Build does not support the billing request"
        case .requestFailed: return "Grok Build billing request failed"
        }
    }

    /// The single next step that most often fixes this failure.
    public var recovery: String {
        switch self {
        case .notSignedIn:
            return "Run `grok login`."
        case .agentStartFailed:
            return "Check that `grok` runs in Terminal, then refresh MeterBar."
        case .agentTimedOut:
            return "Refresh again; if it keeps timing out, quit any running `grok` sessions."
        case .unparseableResponse:
            return "Refresh once more, then copy this Diagnostics report if it persists."
        case .unsupportedVersion:
            return "Update Grok Build to a version that reports billing, then refresh."
        case .requestFailed:
            return "Run `grok login` to confirm the CLI works, then refresh MeterBar."
        }
    }

    /// Recovers the failure from an already-sanitized refresh error.
    public init?(message: String) {
        guard let match = Self.allCases.first(where: { $0.message == message }) else { return nil }
        self = match
    }

    /// Whitelist used by the sanitizer: these strings are known-safe verbatim.
    public static let messages: Set<String> = Set(allCases.map(\.message))
}
