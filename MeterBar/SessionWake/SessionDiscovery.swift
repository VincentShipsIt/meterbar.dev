import Foundation

/// Read-only discovery of blocked Claude Code sessions for the selected account.
///
/// Discovery is strictly preview-safe: it only reads transcript tails and the
/// filesystem. It performs no subprocess, no transcript write, no lock
/// mutation, and never reads a directory other than the selected account's.
/// All work runs on this actor, off the main actor, with a bounded tail read
/// per transcript so a huge history cannot stall the scan.
actor SessionDiscovery {
    typealias Configuration = WakeTranscriptScanner.Configuration

    private let scanner: WakeTranscriptScanner

    init(configuration: Configuration = Configuration()) {
        scanner = WakeTranscriptScanner(configuration: configuration)
    }

    /// The `projects` root for an account, honoring an explicit
    /// `CLAUDE_CONFIG_DIR` override and otherwise `~/.claude`.
    static func projectsDirectory(configDirectory: String?) -> URL {
        WakeTranscriptScanner.root(override: configDirectory, defaultHome: ".claude", subdirectory: "projects")
    }

    /// Discover blocked sessions for `configDirectory`, consulting `ledger` to
    /// flag already-handled blocks. Subagent transcripts are excluded outright.
    ///
    /// - Parameter now: reference instant for the transcript-age bound;
    ///   injectable so tests can pin it.
    /// - Returns: one executable-or-skip candidate per unique session, newest
    ///   block first.
    func discover(
        configDirectory: String?,
        ledger: ReplayLedger,
        now: Date = Date()
    ) async -> [WakeSessionCandidate] {
        let projects = SessionDiscovery.projectsDirectory(configDirectory: configDirectory)
        let transcripts = scanner.transcriptURLs(under: projects, now: now, prunesSubagents: true)
        var candidates = WakeTranscriptScanner.CandidateSet()

        for url in transcripts {
            guard let lines = scanner.readTail(of: url) else { continue }
            let fallbackID = url.deletingPathExtension().lastPathComponent
            let summary = TranscriptClassifier.classify(sessionID: fallbackID, lines: lines)

            // Subagent transcripts are never resume targets.
            if summary.isSidechain { continue }

            guard case let .blocked(reason, blockedAt, resetHint) = summary.state else { continue }

            let fingerprint = BlockFingerprint(
                sessionID: summary.sessionID,
                blockedAt: blockedAt,
                reason: reason
            )
            let (canonicalCwd, cwdSkip) = scanner.resolveWorkingDirectory(summary.cwd)
            let alreadyHandled = await ledger.contains(fingerprint)

            let skip: WakeSkipReason? = alreadyHandled ? .alreadyHandled : cwdSkip

            let candidate = WakeSessionCandidate(
                sessionID: summary.sessionID,
                transcriptPath: url.path,
                workingDirectory: canonicalCwd,
                gitBranch: summary.gitBranch,
                reason: reason,
                blockedAt: blockedAt,
                resetHint: resetHint,
                fingerprint: fingerprint,
                skipReason: skip
            )

            candidates.insert(candidate)
        }

        return candidates.sorted
    }
}
