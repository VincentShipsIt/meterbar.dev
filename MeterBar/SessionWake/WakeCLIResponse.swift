import Foundation

/// The versioned JSON contract emitted on `meterbar wake … --json` stdout.
///
/// stdout carries only this object; all diagnostics go to stderr/logs. The
/// `schemaVersion` lets consumers detect breaking changes; new fields are
/// additive within a version.
struct WakeCLIResponse: Codable, Equatable, Sendable, CLIJSONDocument {
    static let currentSchemaVersion = 1

    struct Session: Codable, Equatable, Sendable {
        let sessionID: String
        let reason: String
        let executable: Bool
        let skipReason: String?
        let workingDirectory: String?
    }

    struct Summary: Codable, Equatable, Sendable {
        var resumed = 0
        var failed = 0
        var skipped = 0
        var remaining = 0
    }

    var schemaVersion = currentSchemaVersion
    let outcome: WakeCLIOutcome
    let provider: String
    let dryRun: Bool
    /// The selected account's config directory (nil ⇒ default `~/.claude`).
    let account: String?
    let eligibleCount: Int
    let sessions: [Session]
    var summary: Summary
    /// Human-readable, machine-stable reason for a non-success outcome.
    let message: String?

    static func from(
        candidates: [WakeSessionCandidate],
        outcome: WakeCLIOutcome,
        provider: String,
        dryRun: Bool,
        account: String?,
        summary: Summary = Summary(),
        message: String? = nil
    ) -> WakeCLIResponse {
        WakeCLIResponse(
            outcome: outcome,
            provider: provider,
            dryRun: dryRun,
            account: account,
            eligibleCount: candidates.filter(\.isExecutable).count,
            sessions: candidates.map {
                Session(
                    sessionID: $0.sessionID,
                    reason: $0.reason.rawValue,
                    executable: $0.isExecutable,
                    skipReason: $0.skipReason?.rawValue,
                    workingDirectory: $0.workingDirectory
                )
            },
            summary: summary,
            message: message
        )
    }
}
