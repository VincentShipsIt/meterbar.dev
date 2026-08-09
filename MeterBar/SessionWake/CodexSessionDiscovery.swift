import Foundation

/// Read-only discovery of blocked Codex sessions for the selected CODEX_HOME.
///
/// Mirrors `SessionDiscovery` (bounded newest-first enumeration, tail reads, no
/// mutation) but over Codex's rollout layout: `<CODEX_HOME>/sessions/YYYY/MM/DD/
/// rollout-<iso>-<uuid>.jsonl`. Classification is delegated to
/// `CodexRolloutClassifier`, which keys the block signal on the structured
/// `rate_limits.rate_limit_reached_type` field rather than any prose.
actor CodexSessionDiscovery {
    typealias Configuration = WakeTranscriptScanner.Configuration

    private let scanner: WakeTranscriptScanner

    init(configuration: Configuration = Configuration()) {
        scanner = WakeTranscriptScanner(configuration: configuration)
    }

    /// The `sessions` root for a CODEX_HOME, honoring an explicit override and
    /// otherwise `~/.codex`.
    static func sessionsDirectory(codexHome: String?) -> URL {
        WakeTranscriptScanner.root(override: codexHome, defaultHome: ".codex", subdirectory: "sessions")
    }

    /// Discover blocked Codex sessions under `codexHome`, consulting `ledger` to
    /// flag already-handled blocks.
    func discover(
        codexHome: String?,
        ledger: ReplayLedger,
        now: Date = Date()
    ) async -> [WakeSessionCandidate] {
        let sessions = CodexSessionDiscovery.sessionsDirectory(codexHome: codexHome)
        let rollouts = scanner.transcriptURLs(under: sessions, now: now, prunesSubagents: false)
        var candidates = WakeTranscriptScanner.CandidateSet()

        for url in rollouts {
            guard let lines = scanner.readTail(of: url) else { continue }
            let fallbackID = url.deletingPathExtension().lastPathComponent
            let summary = CodexRolloutClassifier.classify(fallbackID: fallbackID, lines: lines)

            guard case let .blocked(reason, blockedAt, resetHint) = summary.state else { continue }

            let fingerprint = BlockFingerprint(
                sessionID: summary.sessionID,
                blockedAt: blockedAt,
                reason: reason,
                provider: .codex
            )
            let (canonicalCwd, cwdSkip) = scanner.resolveWorkingDirectory(summary.cwd)
            let alreadyHandled = await ledger.contains(fingerprint)
            let skip: WakeSkipReason? = alreadyHandled ? .alreadyHandled : cwdSkip

            let candidate = WakeSessionCandidate(
                sessionID: summary.sessionID,
                transcriptPath: url.path,
                workingDirectory: canonicalCwd,
                gitBranch: nil,
                reason: reason,
                blockedAt: blockedAt,
                resetHint: resetHint,
                fingerprint: fingerprint,
                skipReason: skip,
                provider: .codex
            )

            candidates.insert(candidate)
        }

        return candidates.sorted
    }
}
