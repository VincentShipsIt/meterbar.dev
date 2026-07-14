import Foundation

/// Pure, testable provider-readiness check logic shared by the app and the CLI.
///
/// This is the single core behind three surfaces: the `meterbar doctor` CLI
/// subcommand, the app's Diagnostics view, and the first-run/empty-state
/// checklist. Lives in `MeterBarShared` — mirroring how the wire-format metrics
/// types were unified — so `MeterBarCLI` and `MeterBar` genuinely share it
/// instead of each re-deriving the checks.
///
/// The evaluators are pure functions of fixture-able inputs: the impure
/// gathering (PATH scan, keychain, `CODEX_HOME/auth.json`, Cursor SQLite) is done
/// by `ProviderReadinessInspector` in the app target. Every string produced here
/// is safe to paste into a public GitHub issue — no token, account id, or raw
/// file/response body is ever emitted.

// MARK: - Result types

/// Severity of a single readiness check.
public enum ReadinessLevel: String, Codable, Sendable, CaseIterable {
    case pass
    case warn
    case fail

    /// Ordering used to roll individual checks up into an overall status.
    public var severity: Int {
        switch self {
        case .pass: return 0
        case .warn: return 1
        case .fail: return 2
        }
    }
}

/// Stable identifiers for the ordered checks every provider reports, so surfaces
/// can look up a specific check without stringly-typed drift.
public enum ReadinessCheckID {
    public static let installed = "installed"
    public static let auth = "auth"
    public static let data = "data"
    public static let refresh = "refresh"
    public static let parseHealth = "parse-health"
}

/// One evaluated check: a pass/warn/fail plus a redacted, plain-language detail
/// and an optional recovery action the user can act on.
public struct ReadinessCheck: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let level: ReadinessLevel
    public let detail: String
    public let recovery: String?

    public init(id: String, title: String, level: ReadinessLevel, detail: String, recovery: String? = nil) {
        self.id = id
        self.title = title
        self.level = level
        self.detail = detail
        self.recovery = recovery
    }
}

/// The full readiness report for one provider: an ordered list of checks
/// (installed → auth → data → refresh) plus a rolled-up overall status.
public struct ProviderReadiness: Codable, Sendable, Equatable, Identifiable {
    public let provider: ServiceType
    public let checks: [ReadinessCheck]

    public init(provider: ServiceType, checks: [ReadinessCheck]) {
        self.provider = provider
        self.checks = checks
    }

    public var id: String { provider.rawValue }

    /// The worst level across all checks (fail > warn > pass).
    public var overall: ReadinessLevel {
        checks.map(\.level).max(by: { $0.severity < $1.severity }) ?? .pass
    }

    public var isHealthy: Bool { overall == .pass }

    public func check(_ id: String) -> ReadinessCheck? {
        checks.first { $0.id == id }
    }
}

/// Rolled-up provider counts shared by dashboard diagnostics and tests.
public struct ProviderReadinessSummary: Sendable, Equatable {
    public let ready: Int
    public let warning: Int
    public let attention: Int

    public init(reports: [ProviderReadiness]) {
        ready = reports.filter { $0.overall == .pass }.count
        warning = reports.filter { $0.overall == .warn }.count
        attention = reports.filter { $0.overall == .fail }.count
    }

    public var displayText: String {
        "\(ready) ready · \(warning) \(warning == 1 ? "warning" : "warnings") · " +
            "\(attention) \(attention == 1 ? "needs attention" : "need attention")"
    }
}

// MARK: - Inputs

/// Outcome of probing Cursor's local SQLite state database. Modeled as an enum
/// because the database read (SQLite, on a file that locks while Cursor runs)
/// cannot be exercised purely — the impure inspector maps the real read onto
/// one of these cases and the evaluator turns it into checks.
public enum CursorDatabaseProbe: String, Codable, Sendable, Equatable {
    /// No `state.vscdb` found in any known location.
    case notFound
    /// Found, but the file could not be opened/read (permissions or Cursor lock).
    case unreadable
    /// Readable, but no `cursorAuth/accessToken` row — not signed in.
    case missingToken
    /// Readable and a session token is present.
    case tokenPresent
}

/// Fixture-able facts for the Claude Code readiness evaluation.
public struct ClaudeReadinessInput: Sendable {
    /// `claude` resolvable on PATH.
    public var isCLIInstalled: Bool
    /// Raw keychain blob for the "Claude Code-credentials" item (nil if absent).
    /// This is the *legacy OAuth fallback* path only — the standard `claude
    /// login` CLI session stores credentials the app cannot read, so a nil
    /// blob must not by itself mean "not signed in".
    public var credentialsJSON: Data?
    /// Usage metrics for Claude Code were successfully fetched recently.
    /// Fetches run through the `claude` CLI session, so a recent success is
    /// direct proof of a working sign-in even when no keychain blob is
    /// readable (the standard CLI-login flow).
    public var hasRecentUsageFetch: Bool
    /// Pre-sanitized last-refresh error (safe to display), nil on success.
    public var refreshError: String?
    public var now: Date

    public init(
        isCLIInstalled: Bool,
        credentialsJSON: Data? = nil,
        hasRecentUsageFetch: Bool = false,
        refreshError: String? = nil,
        now: Date = Date()
    ) {
        self.isCLIInstalled = isCLIInstalled
        self.credentialsJSON = credentialsJSON
        self.hasRecentUsageFetch = hasRecentUsageFetch
        self.refreshError = refreshError
        self.now = now
    }
}

/// Fixture-able facts for the Codex CLI readiness evaluation.
public struct CodexReadinessInput: Sendable {
    /// `codex` resolvable on PATH.
    public var isCLIInstalled: Bool
    /// `CODEX_HOME/auth.json` exists on disk (`CODEX_HOME` defaults to `~/.codex`).
    public var authFileExists: Bool
    /// The auth file could be read (exists and permissions allow it).
    public var authFileReadable: Bool
    /// Raw `CODEX_HOME/auth.json` bytes when readable, else nil.
    public var authJSON: Data?
    /// Pre-sanitized last-refresh error (safe to display), nil on success.
    public var refreshError: String?
    public var now: Date

    public init(
        isCLIInstalled: Bool,
        authFileExists: Bool,
        authFileReadable: Bool,
        authJSON: Data? = nil,
        refreshError: String? = nil,
        now: Date = Date()
    ) {
        self.isCLIInstalled = isCLIInstalled
        self.authFileExists = authFileExists
        self.authFileReadable = authFileReadable
        self.authJSON = authJSON
        self.refreshError = refreshError
        self.now = now
    }
}

/// Fixture-able facts for the Cursor readiness evaluation.
public struct CursorReadinessInput: Sendable {
    /// Cursor is installed (its app bundle and/or state database are present).
    public var isInstalled: Bool
    /// Outcome of probing the Cursor state database for the session token.
    public var database: CursorDatabaseProbe
    /// Pre-sanitized last-refresh error (safe to display), nil on success.
    public var refreshError: String?
    public var now: Date

    public init(
        isInstalled: Bool,
        database: CursorDatabaseProbe,
        refreshError: String? = nil,
        now: Date = Date()
    ) {
        self.isInstalled = isInstalled
        self.database = database
        self.refreshError = refreshError
        self.now = now
    }
}

/// Fixture-able facts for the API-key-backed OpenRouter provider.
public struct OpenRouterReadinessInput: Sendable {
    public var hasAPIKey: Bool
    public var refreshError: String?

    public init(hasAPIKey: Bool, refreshError: String? = nil) {
        self.hasAPIKey = hasAPIKey
        self.refreshError = refreshError
    }
}

/// Fixture-able facts for the Grok Build CLI-backed provider. The inspector
/// checks only file existence/readability; credential contents stay private to
/// the official CLI process.
public struct GrokReadinessInput: Sendable {
    public var isCLIInstalled: Bool
    public var authFileExists: Bool
    public var authFileReadable: Bool
    public var refreshError: String?

    public init(
        isCLIInstalled: Bool,
        authFileExists: Bool,
        authFileReadable: Bool,
        refreshError: String? = nil
    ) {
        self.isCLIInstalled = isCLIInstalled
        self.authFileExists = authFileExists
        self.authFileReadable = authFileReadable
        self.refreshError = refreshError
    }
}

// MARK: - Evaluator

public enum ProviderReadinessEvaluator {
    // MARK: Claude Code

    public static func claudeCode(_ input: ClaudeReadinessInput) -> ProviderReadiness {
        let installed = ReadinessCheck(
            id: ReadinessCheckID.installed,
            title: "CLI installed",
            level: input.isCLIInstalled ? .pass : .fail,
            detail: input.isCLIInstalled
                ? "Claude Code CLI found on PATH."
                : "Claude Code CLI not found on PATH.",
            recovery: input.isCLIInstalled ? nil : "Install Claude Code, then run `claude login`."
        )

        let auth = claudeAuthCheck(input)

        let dataReady = input.isCLIInstalled && auth.level == .pass
        let data = ReadinessCheck(
            id: ReadinessCheckID.data,
            title: "Usage readable",
            level: dataReady ? .pass : .warn,
            detail: dataReady
                ? "Usage is readable via the Claude CLI."
                : "Usage becomes readable once the CLI is installed and signed in."
        )

        return ProviderReadiness(
            provider: .claudeCode,
            checks: [installed, auth, data, refreshCheck(input.refreshError)]
        )
    }

    private static func claudeAuthCheck(_ input: ClaudeReadinessInput) -> ReadinessCheck {
        let loginRecovery = "Run `claude login`."

        // Direct proof beats credential inspection: usage fetches run through
        // the `claude` CLI session, so a recent success means the sign-in
        // works — regardless of whether the legacy keychain blob is readable
        // (it usually isn't for the standard CLI-login flow).
        if input.hasRecentUsageFetch {
            return ReadinessCheck(
                id: ReadinessCheckID.auth,
                title: "Signed in",
                level: .pass,
                detail: "Signed in — usage was recently read through the Claude CLI session."
            )
        }

        if let data = input.credentialsJSON,
           let credentials = try? JSONDecoder().decode(ClaudeCredentialsFixture.self, from: data) {
            guard let accessToken = credentials.claudeAiOauth.accessToken?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !accessToken.isEmpty else {
                return ReadinessCheck(
                    id: ReadinessCheckID.auth,
                    title: "Signed in",
                    level: .fail,
                    detail: "Claude Code credentials do not contain a usable access token.",
                    recovery: loginRecovery
                )
            }

            if let expiresAt = credentials.claudeAiOauth.expiresAt,
               OAuthTokenExpiry.isExpired(unixTimestamp: expiresAt, now: input.now) {
                return ReadinessCheck(
                    id: ReadinessCheckID.auth,
                    title: "Signed in",
                    level: .fail,
                    detail: "Claude Code session has expired.",
                    recovery: loginRecovery
                )
            }

            return ReadinessCheck(
                id: ReadinessCheckID.auth,
                title: "Signed in",
                level: .pass,
                detail: "Signed in to Claude Code."
            )
        }

        // No working fetch and no readable credentials. If the CLI is
        // installed this is inconclusive rather than a proven logout — the
        // CLI-login session isn't inspectable from here — so warn instead of
        // reporting a hard failure for a setup that may be perfectly healthy.
        if input.isCLIInstalled {
            return ReadinessCheck(
                id: ReadinessCheckID.auth,
                title: "Signed in",
                level: .warn,
                detail: "Sign-in not verified yet — no recent usage fetch and no readable credentials.",
                recovery: "Open MeterBar to trigger a refresh, or run `claude login` if usage stays empty."
            )
        }

        return ReadinessCheck(
            id: ReadinessCheckID.auth,
            title: "Signed in",
            level: .fail,
            detail: "Not signed in — no Claude Code credentials found.",
            recovery: loginRecovery
        )
    }

    // MARK: Codex CLI

    public static func codexCli(_ input: CodexReadinessInput) -> ProviderReadiness {
        // The app reads CODEX_HOME/auth.json directly and never execs `codex`, so a
        // missing binary is a soft warning rather than a hard failure.
        let installed = ReadinessCheck(
            id: ReadinessCheckID.installed,
            title: "CLI installed",
            level: input.isCLIInstalled ? .pass : .warn,
            detail: input.isCLIInstalled
                ? "Codex CLI found on PATH."
                : "Codex CLI not found on PATH (usage is still read from CODEX_HOME/auth.json).",
            recovery: input.isCLIInstalled ? nil : "Install the Codex CLI (`npm i -g @openai/codex`) to use `codex login`."
        )

        let auth = codexAuthCheck(input)

        let dataReady = input.authFileReadable && auth.level == .pass
        let data = ReadinessCheck(
            id: ReadinessCheckID.data,
            title: "Usage readable",
            level: dataReady ? .pass : .warn,
            detail: dataReady
                ? "Subscription usage is readable from CODEX_HOME/auth.json."
                : "Subscription usage requires a readable Codex OAuth login."
        )

        return ProviderReadiness(
            provider: .codexCli,
            checks: [installed, auth, data, refreshCheck(input.refreshError)]
        )
    }

    private static func codexAuthCheck(_ input: CodexReadinessInput) -> ReadinessCheck {
        let loginRecovery = "Run `codex login`."
        let title = "Signed in"

        guard input.authFileExists else {
            return ReadinessCheck(
                id: ReadinessCheckID.auth,
                title: title,
                level: .fail,
                detail: "Not signed in — no CODEX_HOME/auth.json found.",
                recovery: loginRecovery
            )
        }

        guard input.authFileReadable, let data = input.authJSON else {
            return ReadinessCheck(
                id: ReadinessCheckID.auth,
                title: title,
                level: .fail,
                detail: "CODEX_HOME/auth.json exists but could not be read.",
                recovery: "Check the permissions on CODEX_HOME/auth.json, then run `codex login`."
            )
        }

        guard let auth = try? JSONDecoder().decode(CodexAuthFixture.self, from: data) else {
            return ReadinessCheck(
                id: ReadinessCheckID.auth,
                title: title,
                level: .fail,
                detail: "CODEX_HOME/auth.json could not be parsed.",
                recovery: loginRecovery
            )
        }

        guard let token = auth.tokens?.accessToken, !token.isEmpty else {
            if let apiKey = auth.openaiApiKey, !apiKey.isEmpty {
                return ReadinessCheck(
                    id: ReadinessCheckID.auth,
                    title: title,
                    level: .fail,
                    detail: "An OpenAI API key is present, but subscription quota requires a Codex OAuth login.",
                    recovery: loginRecovery
                )
            }
            return ReadinessCheck(
                id: ReadinessCheckID.auth,
                title: title,
                level: .fail,
                detail: "Not signed in — no OAuth token in CODEX_HOME/auth.json.",
                recovery: loginRecovery
            )
        }

        if OAuthTokenExpiry.isExpired(jwt: token, now: input.now) {
            return ReadinessCheck(
                id: ReadinessCheckID.auth,
                title: title,
                level: .fail,
                detail: "Codex access token has expired.",
                recovery: loginRecovery
            )
        }

        return ReadinessCheck(
            id: ReadinessCheckID.auth,
            title: title,
            level: .pass,
            detail: "Signed in to Codex."
        )
    }

    // MARK: Cursor

    public static func cursor(_ input: CursorReadinessInput) -> ProviderReadiness {
        let installed = ReadinessCheck(
            id: ReadinessCheckID.installed,
            title: "Installed",
            level: input.isInstalled ? .pass : .fail,
            detail: input.isInstalled
                ? "Cursor is installed."
                : "Cursor was not found on this Mac.",
            recovery: input.isInstalled ? nil : "Install Cursor and sign in."
        )

        let auth = cursorAuthCheck(input.database)

        let dataReadable = input.database == .tokenPresent || input.database == .missingToken
        let data = ReadinessCheck(
            id: ReadinessCheckID.data,
            title: "Data readable",
            level: dataReadable ? .pass : .fail,
            detail: dataReadable
                ? "Cursor's local database is readable."
                : "Cursor's local database could not be read."
        )

        return ProviderReadiness(
            provider: .cursor,
            checks: [installed, auth, data, refreshCheck(input.refreshError)]
        )
    }

    private static func cursorAuthCheck(_ probe: CursorDatabaseProbe) -> ReadinessCheck {
        let title = "Signed in"
        switch probe {
        case .tokenPresent:
            return ReadinessCheck(id: ReadinessCheckID.auth, title: title, level: .pass, detail: "Signed in to Cursor.")
        case .missingToken:
            return ReadinessCheck(
                id: ReadinessCheckID.auth,
                title: title,
                level: .fail,
                detail: "Not signed in to Cursor.",
                recovery: "Open Cursor and sign in."
            )
        case .notFound:
            return ReadinessCheck(
                id: ReadinessCheckID.auth,
                title: title,
                level: .fail,
                detail: "Cursor's local database was not found.",
                recovery: "Open Cursor and sign in."
            )
        case .unreadable:
            return ReadinessCheck(
                id: ReadinessCheckID.auth,
                title: title,
                level: .fail,
                detail: "Cursor's local database could not be read.",
                recovery: "Quit Cursor (its database locks while running), then rescan."
            )
        }
    }

    // MARK: OpenRouter

    public static func openRouter(_ input: OpenRouterReadinessInput) -> ProviderReadiness {
        let installed = ReadinessCheck(
            id: ReadinessCheckID.installed,
            title: "App required",
            level: .pass,
            detail: "No local OpenRouter app or CLI is required."
        )
        let auth = ReadinessCheck(
            id: ReadinessCheckID.auth,
            title: "API key",
            level: input.hasAPIKey ? .pass : .fail,
            detail: input.hasAPIKey ? "OpenRouter API key is configured." : "OpenRouter API key is missing.",
            recovery: input.hasAPIKey ? nil : "Add an API key in MeterBar Settings."
        )
        let data = ReadinessCheck(
            id: ReadinessCheckID.data,
            title: "Usage readable",
            level: input.hasAPIKey ? .pass : .warn,
            detail: input.hasAPIKey
                ? "Credits and per-key limits can be fetched from OpenRouter."
                : "Usage becomes readable after an API key is configured."
        )
        return ProviderReadiness(
            provider: .openRouter,
            checks: [installed, auth, data, refreshCheck(input.refreshError)]
        )
    }

    // MARK: Grok

    public static func grok(_ input: GrokReadinessInput) -> ProviderReadiness {
        let installed = ReadinessCheck(
            id: ReadinessCheckID.installed,
            title: "CLI installed",
            level: input.isCLIInstalled ? .pass : .fail,
            detail: input.isCLIInstalled ? "Grok Build CLI found on PATH." : "Grok Build CLI not found on PATH.",
            recovery: input.isCLIInstalled ? nil : "Install Grok Build, then run `grok login`."
        )
        let authLevel: ReadinessLevel = input.authFileReadable ? .pass : .fail
        let auth = ReadinessCheck(
            id: ReadinessCheckID.auth,
            title: "Signed in",
            level: authLevel,
            detail: input.authFileReadable
                ? "A readable Grok Build cached login is available."
                : input.authFileExists
                    ? "Grok Build cached login exists but could not be read."
                    : "Not signed in — no Grok Build cached login found.",
            recovery: input.authFileReadable ? nil : "Run `grok login`."
        )
        let dataReady = input.isCLIInstalled && input.authFileReadable
        let data = ReadinessCheck(
            id: ReadinessCheckID.data,
            title: "Usage readable",
            level: dataReady ? .pass : .warn,
            detail: dataReady
                ? "Weekly usage is readable through the Grok Build ACP billing method."
                : "Usage becomes readable once Grok Build is installed and signed in."
        )
        return ProviderReadiness(
            provider: .grok,
            checks: [installed, auth, data, refreshCheck(input.refreshError)]
        )
    }

    // MARK: Shared

    private static func refreshCheck(_ error: String?) -> ReadinessCheck {
        guard let error, !error.isEmpty else {
            return ReadinessCheck(
                id: ReadinessCheckID.refresh,
                title: "Last refresh",
                level: .pass,
                detail: "No recent refresh errors."
            )
        }
        return ReadinessCheck(
            id: ReadinessCheckID.refresh,
            title: "Last refresh",
            level: .fail,
            detail: "Last refresh failed: \(error)"
        )
    }
}

// MARK: - Minimal auth-file decoders

// Purpose-built decoders for just the fields readiness needs. The authoritative
// decoders live in the provider services (ClaudeCodeCredentials / CodexAuthFile);
// these read a couple of fields each so the pure core can be fixture-tested
// without linking the app-only models. Keep field mappings in sync if the auth
// file formats change.

private struct ClaudeCredentialsFixture: Decodable {
    struct OAuth: Decodable {
        let accessToken: String?
        let expiresAt: Int64?
    }
    let claudeAiOauth: OAuth
}

private struct CodexAuthFixture: Decodable {
    struct Tokens: Decodable {
        let accessToken: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }
    let openaiApiKey: String?
    let tokens: Tokens?

    enum CodingKeys: String, CodingKey {
        case openaiApiKey = "OPENAI_API_KEY"
        case tokens
    }
}
