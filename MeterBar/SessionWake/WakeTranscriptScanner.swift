import Foundation

/// Shared bounded filesystem mechanics for provider-specific wake discovery.
///
/// Classification stays with each provider so their transcript contracts
/// cannot bleed together; only their identical read, validation, and ordering
/// rules live here.
nonisolated struct WakeTranscriptScanner {
    struct Configuration {
        /// Bytes read from the end of each transcript. The decisive tail of a
        /// session is always near the end, so a bounded window is sufficient
        /// and keeps scanning incremental.
        var maxTailBytes: Int = 64 * 1024
        /// Transcripts whose file was not modified within this window are
        /// skipped outright — a weeks-old block is history, not a wake target.
        var maxTranscriptAge: TimeInterval = 14 * 24 * 3600
        /// Newest-first cap on transcripts classified per scan, so a huge
        /// transcript directory can never make discovery unbounded.
        var maxTranscripts: Int = 400
        var fileManager: FileManager = .default
    }

    struct CandidateSet {
        private var bySession: [String: WakeSessionCandidate] = [:]

        mutating func insert(_ candidate: WakeSessionCandidate) {
            if let existing = bySession[candidate.sessionID],
               !WakeTranscriptScanner.supersedes(candidate, existing) {
                return
            }
            bySession[candidate.sessionID] = candidate
        }

        /// `supersedes` is a strict total order over (blockedAt desc, path asc);
        /// reusing it keeps the dedupe winner and the output order one rule.
        var sorted: [WakeSessionCandidate] {
            bySession.values.sorted(by: WakeTranscriptScanner.supersedes)
        }
    }

    private let configuration: Configuration

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Resolve a provider root consistently across every account layout.
    ///
    /// A non-blank override is standardized so tildes expand, `..` components
    /// collapse, and trailing slashes are removed before the subdirectory is
    /// appended.
    static func root(override: String?, defaultHome: String, subdirectory: String) -> URL {
        let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        if let trimmed, !trimmed.isEmpty {
            base = (trimmed as NSString).standardizingPath
        } else {
            base = "\(ServiceSupport.realHomeDirectory())/\(defaultHome)"
        }
        return URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent(subdirectory, isDirectory: true)
    }

    /// Bounded enumeration of recent regular `.jsonl` files, newest first.
    func transcriptURLs(under root: URL, now: Date, prunesSubagents: Bool) -> [URL] {
        guard let enumerator = configuration.fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let oldestAllowed = now.addingTimeInterval(-configuration.maxTranscriptAge)
        var found: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            // Subagent transcripts are never resume targets. Pruning their
            // directory avoids stat'ing every child before classification.
            if prunesSubagents, url.lastPathComponent == "subagents", url.hasDirectoryPath {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "jsonl",
                  !prunesSubagents || !url.pathComponents.contains("subagents"),
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
        // A path tie-break keeps the cap independent of filesystem enumeration
        // order when multiple transcripts share a modification instant.
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
    func readTail(of url: URL) -> [String]? {
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
    func resolveWorkingDirectory(_ raw: String?) -> (String?, WakeSkipReason?) {
        guard let raw, !raw.isEmpty else { return (nil, .unknownWorkingDirectory) }
        let canonical = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        let exists = configuration.fileManager.fileExists(atPath: canonical, isDirectory: &isDirectory)
        if !exists || !isDirectory.boolValue {
            return (canonical, .missingWorkingDirectory)
        }
        return (canonical, nil)
    }

    /// Deterministic dedupe: the latest block wins; equal block instants
    /// tie-break on the lexicographically first transcript path so the winner
    /// never depends on filesystem enumeration order.
    static func supersedes(_ candidate: WakeSessionCandidate, _ existing: WakeSessionCandidate) -> Bool {
        if candidate.blockedAt != existing.blockedAt {
            return candidate.blockedAt > existing.blockedAt
        }
        return candidate.transcriptPath < existing.transcriptPath
    }
}
