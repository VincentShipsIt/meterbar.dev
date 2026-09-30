import Foundation

/// The stable provider tokens every CLI JSON document uses (`docs/cli-json-schema.md`).
///
/// They live here, not beside the CLI commands, because the routing decision
/// contract in this package has to speak the same tokens: `refresh --json`,
/// `usage --json`, `guard --json` and `route --json` must never drift into a
/// second mapping.
public extension ServiceType {
    var cliIdentifier: String {
        switch self {
        case .claudeCode: "claude"
        case .codexCli: "codex"
        case .cursor: "cursor"
        case .openRouter: "openrouter"
        case .grok: "grok"
        case .kimiCode: "kimi"
        case .zaiCodingPlan: "zai"
        case .githubCopilot: "copilot"
        }
    }

    /// The same tokens in documented order, for `--provider` help and error text.
    static var cliIdentifiers: String {
        allCases.sorted { $0.sortOrder < $1.sortOrder }
            .map(\.cliIdentifier)
            .joined(separator: ", ")
    }

    /// Parses a caller-supplied `--provider` value. Tolerant of surrounding
    /// whitespace and casing so shell interpolation doesn't become a usage error.
    static func fromCLIIdentifier(_ raw: String) -> ServiceType? {
        let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCases.first { $0.cliIdentifier == needle }
    }
}

public extension QuotaBand {
    var cliIdentifier: String {
        switch self {
        case .healthy: "healthy"
        case .tight: "tight"
        case .critical: "critical"
        case .exhausted: "exhausted"
        }
    }
}
