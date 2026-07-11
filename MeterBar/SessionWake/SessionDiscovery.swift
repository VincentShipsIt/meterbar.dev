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
        /// Transcripts whose file was not modified within this window are
        /// skipped outright — a weeks-old block is history, not a wake target.
        var maxTranscriptAge: TimeInterval = 14 * 24 * 3600
        /// Newest-first cap on transcripts classified per scan, so a huge
        /// projects directory can never make discovery unbounded.
        var maxTranscripts: Int = 400
        var fileManager: FileManager = .default

        init(
            maxTailBytes: Int = 64 * 1024,
            maxTranscriptAge: TimeInterval = 14 * 24 * 3600,
            maxTranscripts: Int = 400,
            fileManager: FileManager = .default
        ) {
            self.maxTailBytes = maxTailBytes
            self.maxTranscriptAge = maxTranscriptAge
            self.maxTranscripts = maxTranscripts
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
        let transcripts = transcriptURLs(under: projects, now: now)

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

            if let existing = bySession[summary.sessionID], !supersedes(candidate, existing) {
                continue
            }
            bySession[summary.sessionID] = candidate
        }

        // `supersedes` is a strict total order over (blockedAt desc, path asc);
        // reusing it keeps the dedupe winner and the output order one rule.
        return bySession.values.sorted(by: supersedes)
    }

    /// Deterministic dedupe: the latest block wins; equal block instants
    /// tie-break on the lexicographically first transcript path so the winner
    /// never depends on filesystem enumeration order.
    private func supersedes(_ candidate: WakeSessionCandidate, _ existing: WakeSessionCandidate) -> Bool {
        if candidate.blockedAt != existing.blockedAt {
            return candidate.blockedAt > existing.blockedAt
        }
        return candidate.transcriptPath < existing.transcriptPath
    }

    // MARK: - Filesystem

    /// Bounded enumeration: recent regular `.jsonl` files outside any
    /// `subagents/` directory, newest-first, capped at `maxTranscripts`.
    private func transcriptURLs(under projects: URL, now: Date) -> [URL] {
        guard let enumerator = configuration.fileManager.enumerator(
            at: projects,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let oldestAllowed = now.addingTimeInterval(-configuration.maxTranscriptAge)
        var found: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            // Subagent transcripts live under a `subagents/` directory and are
            // never resume targets — prune the whole subtree so its children
            // are never even stat'd.
            if url.lastPathComponent == "subagents", url.hasDirectoryPath {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "jsonl",
                  !url.pathComponents.contains("subagents"),
                  let values = try? url.resourceValues(
                      forKeys: [.isRegularFileKey, .contentModificationDateKey]
                  ),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= oldestAllowed else {
                continue
            }
            found.append((url, modified))
        }
        // Newest-first with a lexicographic path tie-break, so the winners
        // under the cap never depend on filesystem enumeration order.
        return found
            .sorted {
                if $0.modified != $1.modified {
                    return $0.modified > $1.modified
                }
                return $0.url.path < $1.url.path
            }
            .prefix(configuration.maxTranscripts)
            .map(\.url)
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
        // A bounded tail read can begin mid-multibyte-character. A failable
        // String(data:encoding:) would reject the whole buffer and silently
        // drop the transcript's decisive event; lossy decoding turns only the
        // split leading bytes into U+FFFD (that partial line is skipped as
        // malformed JSON) and keeps every complete line intact. The lint rule
        // prefers the failable initializer — exactly the nil-dropping behavior
        // this fix removes — so it is disabled here deliberately.
        // swiftlint:disable:next optional_data_string_conversion
        let string = String(decoding: data, as: UTF8.self)
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
