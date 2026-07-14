import Foundation

/// Read-only discovery of blocked Codex sessions for the selected CODEX_HOME.
///
/// Mirrors `SessionDiscovery` (bounded newest-first enumeration, tail reads, no
/// mutation) but over Codex's rollout layout: `<CODEX_HOME>/sessions/YYYY/MM/DD/
/// rollout-<iso>-<uuid>.jsonl`. Classification is delegated to
/// `CodexRolloutClassifier`, which keys the block signal on the structured
/// `rate_limits.rate_limit_reached_type` field rather than any prose.
actor CodexSessionDiscovery {
    struct Configuration {
        var maxTailBytes: Int = 64 * 1024
        var maxTranscriptAge: TimeInterval = 14 * 24 * 3600
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

    /// The `sessions` root for a CODEX_HOME, honoring an explicit override and
    /// otherwise `~/.codex`.
    static func sessionsDirectory(codexHome: String?) -> URL {
        let trimmed = codexHome?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        if let trimmed, !trimmed.isEmpty {
            base = (trimmed as NSString).standardizingPath
        } else {
            base = "\(ServiceSupport.realHomeDirectory())/.codex"
        }
        return URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Discover blocked Codex sessions under `codexHome`, consulting `ledger` to
    /// flag already-handled blocks.
    func discover(
        codexHome: String?,
        ledger: ReplayLedger,
        now: Date = Date()
    ) async -> [WakeSessionCandidate] {
        let sessions = CodexSessionDiscovery.sessionsDirectory(codexHome: codexHome)
        let rollouts = rolloutURLs(under: sessions, now: now)

        var bySession: [String: WakeSessionCandidate] = [:]

        for url in rollouts {
            guard let lines = readTail(of: url) else { continue }
            let fallbackID = url.deletingPathExtension().lastPathComponent
            let summary = CodexRolloutClassifier.classify(fallbackID: fallbackID, lines: lines)

            guard case let .blocked(reason, blockedAt, resetHint) = summary.state else { continue }

            let fingerprint = BlockFingerprint(
                sessionID: summary.sessionID,
                blockedAt: blockedAt,
                reason: reason,
                provider: .codex
            )
            let (canonicalCwd, cwdSkip) = resolveWorkingDirectory(summary.cwd)
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

            if let existing = bySession[summary.sessionID], !supersedes(candidate, existing) {
                continue
            }
            bySession[summary.sessionID] = candidate
        }

        return bySession.values.sorted(by: supersedes)
    }

    private func supersedes(_ candidate: WakeSessionCandidate, _ existing: WakeSessionCandidate) -> Bool {
        if candidate.blockedAt != existing.blockedAt {
            return candidate.blockedAt > existing.blockedAt
        }
        return candidate.transcriptPath < existing.transcriptPath
    }

    // MARK: - Filesystem

    private func rolloutURLs(under sessions: URL, now: Date) -> [URL] {
        guard let enumerator = configuration.fileManager.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let oldestAllowed = now.addingTimeInterval(-configuration.maxTranscriptAge)
        var found: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
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

    private func readTail(of url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(configuration.maxTailBytes)
            ? size - UInt64(configuration.maxTailBytes)
            : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        // Lossy decode for the same reason SessionDiscovery uses it: a bounded
        // tail can split a multibyte character and strict decoding would drop
        // the whole buffer.
        // swiftlint:disable:next optional_data_string_conversion
        let string = String(decoding: data, as: UTF8.self)
        return string.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

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
