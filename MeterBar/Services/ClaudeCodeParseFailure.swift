import Foundation

/// The closed set of ways parsing `claude /usage` can fail, together with the
/// exact user-facing message each one produces.
///
/// The parser already knew why it failed — a headless spawn makes the CLI print
/// a session cost summary instead of the usage screen — but that sentence died
/// at the `ServiceError` boundary, where every parse failure collapsed to the
/// payload-free `.parsingError`. Settings then showed "Failed to parse
/// response", which names the symptom and hides the one action that fixes it.
///
/// Every `message` is a **constant** — no interpolation, ever. That is what lets
/// `ServiceSupport` and `ProviderReadinessInspector` pass these through verbatim
/// while still discarding arbitrary parse text: a value that cannot be built
/// from CLI output cannot carry a token, an account id, or a response body.
/// This mirrors `GrokRefreshFailure`, which solves the same problem for the only
/// other provider MeterBar reads by driving a subprocess.
///
/// `nonisolated` because the sanitizers that consult it run off the main actor;
/// the target's default isolation would otherwise pin `messages` to `@MainActor`.
nonisolated enum ClaudeCodeParseFailure: String, Sendable, Equatable, CaseIterable {
    /// `claude /usage` rendered a session cost summary instead of the usage
    /// screen, which is what a non-TTY spawn now gets. No amount of retrying
    /// changes that; the OAuth endpoint is the way through.
    case headlessUsageUnavailable
    /// The output was neither the usage screen nor a cost summary, so no quota
    /// windows could be read out of it.
    case noUsageWindows

    /// The sanitized text shown in Settings → Providers and Diagnostics.
    var message: String {
        switch self {
        case .headlessUsageUnavailable:
            return "Claude CLI returned a cost summary instead of the usage screen"
        case .noUsageWindows:
            return "Claude CLI reported no usage windows"
        }
    }

    /// The single next step that most often fixes this failure.
    var recovery: String {
        switch self {
        case .headlessUsageUnavailable:
            return "Connect Claude Code with OAuth in Settings → Claude Code."
        case .noUsageWindows:
            return "Run `claude /usage` in Terminal to confirm it renders, then refresh MeterBar."
        }
    }

    /// Recovers the failure from an already-sanitized message.
    init?(message: String) {
        guard let match = Self.allCases.first(where: { $0.message == message }) else { return nil }
        self = match
    }

    /// Whitelist used by the sanitizers: these strings are known-safe verbatim.
    static let messages: Set<String> = Set(allCases.map(\.message))
}
