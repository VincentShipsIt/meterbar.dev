import Foundation

/// Read-only discovery of blocked Claude Code sessions for the selected account.
///
/// Discovery is strictly preview-safe: it only reads transcript tails and the
/// filesystem. It performs no subprocess, no transcript write, no lock
/// mutation, and never reads a directory other than the selected account's.
/// All work runs on this actor, off the main actor, with a bounded tail read
/// per transcript so a huge history cannot stall the scan.
actor SessionDiscovery {
    struct Configuration {
        /// Bytes read from the end of each transcript. The decisive tail of a
        /// session is always near the end, so a bounded window is sufficient
        /// and keeps scanning incremental.
        var maxTailBytes: Int = 64 * 1024
        var fileManager: FileManager = .default

        init(maxTailBytes: Int = 64 * 1024, fileManager: FileManager = .default) {
            self.maxTailBytes = maxTailBytes
            self.fileManager = fileManager
        }
    }

    private let configuration: Configuration

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The `projects` root for an account, honoring an explicit
    /// `CLAUDE_CONFIG_DIR` override and otherwise `~/.claude`.
    static func projectsDirectory(configDirectory: String?) -> URL {
        let trimmed = configDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        if let trimmed, !trimmed.isEmpty {
            base = trimmed
        } else {
            base = "\(ServiceSupport.realHomeDirectory())/.claude"
        }
        return URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// Discover blocked sessions for `configDirectory`, consulting `ledger` to
    /// flag already-handled blocks. Subagent transcripts are excluded outright.
    ///
    /// - Returns: one executable-or-skip candidate per unique session, newest
    ///   block first.
    func discover(configDirectory: String?, ledger: ReplayLedger) async -> [WakeSessionCandidate] {
        let projects = SessionDiscovery.projectsDirectory(configDirectory: configDirectory)
        let transcripts = transcriptURLs(under: projects)

        // Keep the newest block per sessionID (a resumed session can re-block).
        var bySession: [String: WakeSessionCandidate] = [:]

        for url in transcripts {
            guard let lines = readTail(of: url) else { continue }
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
            let (canonicalCwd, cwdSkip) = resolveWorkingDirectory(summary.cwd)
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

            if let existing = bySession[summary.sessionID], existing.blockedAt >= blockedAt {
                continue
            }
            bySession[summary.sessionID] = candidate
        }

        return bySession.values.sorted { $0.blockedAt > $1.blockedAt }
    }

    // MARK: - Filesystem

    private func transcriptURLs(under projects: URL) -> [URL] {
        guard let enumerator = configuration.fileManager.enumerator(
            at: projects,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            urls.append(url)
        }
        return urls
    }

    /// Read up to `maxTailBytes` from the end of `url`, returned as lines.
    /// Returns nil only when the file cannot be opened at all.
    private func readTail(of url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(configuration.maxTailBytes)
            ? size - UInt64(configuration.maxTailBytes)
            : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let string = String(data: data, encoding: .utf8) else { return [] }
        return string.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Canonicalize and validate the transcript's working directory.
    private func resolveWorkingDirectory(_ raw: String?) -> (String?, WakeSkipReason?) {
        guard let raw, !raw.isEmpty else { return (nil, .unknownWorkingDirectory) }
        let canonical = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        let exists = configuration.fileManager.fileExists(atPath: canonical, isDirectory: &isDirectory)
        if !exists || !isDirectory.boolValue {
            return (canonical, .missingWorkingDirectory)
        }
        return (canonical, nil)
    }
}
