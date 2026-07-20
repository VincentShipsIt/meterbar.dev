import Combine
import Foundation
import MeterBarShared
import os

nonisolated struct ClaudeFableSession: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case active
        case completed
        case unknown
    }

    let id: String
    let sourceSessionID: String
    let accountID: UUID
    let accountName: String
    let model: String
    let firstObservedAt: Date
    let lastObservedAt: Date
    let state: State

    init(
        sourceSessionID: String,
        accountID: UUID,
        accountName: String,
        model: String,
        firstObservedAt: Date,
        lastObservedAt: Date,
        state: State
    ) {
        id = "\(accountID.uuidString.lowercased()):\(sourceSessionID)"
        self.sourceSessionID = sourceSessionID
        self.accountID = accountID
        self.accountName = accountName
        self.model = model
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.state = state
    }
}

nonisolated struct ClaudeFableProfileDiagnostic: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case scanned
        case unavailable
    }

    let accountID: UUID
    let status: Status
    let scannedTranscriptCount: Int
    let malformedLineCount: Int
}

nonisolated struct ClaudeFableSessionScanResult: Equatable, Sendable {
    let sessions: [ClaudeFableSession]
    let diagnostics: [UUID: ClaudeFableProfileDiagnostic]
}

nonisolated enum ClaudeFableSessionPolicy {
    static let retention: TimeInterval = 30 * 24 * 3600
    static let activeWindow: TimeInterval = 15 * 60
    static let terminalStopReasons: Set<String> = [
        "end_turn",
        "max_tokens",
        "refusal",
        "stop_sequence"
    ]
}

/// Privacy-safe, bounded discovery of Fable sessions in configured Claude
/// profiles. Only structural metadata is retained; transcript content and
/// environment metadata never leave the parser.
actor ClaudeFableSessionScanner {
    nonisolated struct Configuration {
        var maxTranscriptAge: TimeInterval = ClaudeFableSessionPolicy.retention
        var activeWindow: TimeInterval = ClaudeFableSessionPolicy.activeWindow
        var maxTranscriptsPerProfile: Int = 400
        var maxBytesPerTranscript: Int = 4 * 1024 * 1024
        var fileManager: FileManager = .default

        init(
            maxTranscriptAge: TimeInterval = ClaudeFableSessionPolicy.retention,
            activeWindow: TimeInterval = ClaudeFableSessionPolicy.activeWindow,
            maxTranscriptsPerProfile: Int = 400,
            maxBytesPerTranscript: Int = 4 * 1024 * 1024,
            fileManager: FileManager = .default
        ) {
            self.maxTranscriptAge = maxTranscriptAge
            self.activeWindow = activeWindow
            self.maxTranscriptsPerProfile = max(1, maxTranscriptsPerProfile)
            self.maxBytesPerTranscript = max(1, maxBytesPerTranscript)
            self.fileManager = fileManager
        }
    }

    nonisolated private struct Observation {
        let sourceSessionID: String
        var model: String
        var firstObservedAt: Date
        var lastObservedAt: Date
        var lastStopReason: String?
        var isIncomplete: Bool

        mutating func merge(_ other: Observation) {
            firstObservedAt = min(firstObservedAt, other.firstObservedAt)
            if other.lastObservedAt >= lastObservedAt {
                lastObservedAt = other.lastObservedAt
                lastStopReason = other.lastStopReason
                model = other.model
            }
            isIncomplete = isIncomplete || other.isIncomplete
        }
    }

    nonisolated private struct TranscriptCandidate {
        let url: URL
        let modificationDate: Date
        let fileSize: Int
    }

    nonisolated private struct TranscriptRead {
        let lines: [Substring]
        let wasTruncated: Bool
    }

    nonisolated private struct ParsedTranscript {
        let observations: [Observation]
        let malformedLineCount: Int
    }

    nonisolated private struct TranscriptCacheEntry {
        let modificationDate: Date
        let fileSize: Int
        let parsed: ParsedTranscript
    }

    private let configuration: Configuration
    private var transcriptCache: [String: TranscriptCacheEntry] = [:]

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func scan(
        accounts: [ClaudeCodeAccount],
        projectDirectories: [UUID: URL] = [:],
        now: Date = Date()
    ) -> ClaudeFableSessionScanResult {
        var sessions: [ClaudeFableSession] = []
        var diagnostics: [UUID: ClaudeFableProfileDiagnostic] = [:]
        var currentTranscriptPaths = Set<String>()

        for account in accounts where account.isEnabled {
            let projectsDirectory = projectDirectories[account.id] ?? Self.projectsDirectory(for: account)
            let accountResult = scanAccount(account, projectsDirectory: projectsDirectory, now: now)
            sessions.append(contentsOf: accountResult.sessions)
            diagnostics[account.id] = accountResult.diagnostic
            currentTranscriptPaths.formUnion(accountResult.transcriptPaths)
        }
        transcriptCache = transcriptCache.filter { currentTranscriptPaths.contains($0.key) }

        return ClaudeFableSessionScanResult(
            sessions: sessions.sorted(by: Self.isNewer),
            diagnostics: diagnostics
        )
    }

    nonisolated static func projectsDirectory(
        for account: ClaudeCodeAccount,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> URL {
        let rawConfigDirectory = account.configDirectory
            ?? ClaudeCodeAccount.defaultConfigDirectory(
                environment: environment,
                realHomeDirectory: realHomeDirectory
            )
        let configDirectory = expandedPath(rawConfigDirectory, realHomeDirectory: realHomeDirectory)
        return URL(fileURLWithPath: configDirectory, isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    private func scanAccount(
        _ account: ClaudeCodeAccount,
        projectsDirectory: URL,
        now: Date
    ) -> (
        sessions: [ClaudeFableSession],
        diagnostic: ClaudeFableProfileDiagnostic,
        transcriptPaths: [String]
    ) {
        guard isReadableDirectory(projectsDirectory),
              let transcriptURLs = transcriptURLs(under: projectsDirectory, now: now) else {
            return (
                [],
                ClaudeFableProfileDiagnostic(
                    accountID: account.id,
                    status: .unavailable,
                    scannedTranscriptCount: 0,
                    malformedLineCount: 0
                ),
                []
            )
        }

        var observations: [String: Observation] = [:]
        var malformedLineCount = 0

        for transcript in transcriptURLs {
            let parsed = parsedTranscript(for: transcript)
            malformedLineCount += parsed.malformedLineCount
            for observation in parsed.observations {
                if var existing = observations[observation.sourceSessionID] {
                    existing.merge(observation)
                    observations[observation.sourceSessionID] = existing
                } else {
                    observations[observation.sourceSessionID] = observation
                }
            }
        }

        let records = observations.values.map { observation in
            ClaudeFableSession(
                sourceSessionID: observation.sourceSessionID,
                accountID: account.id,
                accountName: account.name,
                model: observation.model,
                firstObservedAt: observation.firstObservedAt,
                lastObservedAt: observation.lastObservedAt,
                state: state(for: observation, now: now)
            )
        }

        return (
            records.sorted(by: Self.isNewer),
            ClaudeFableProfileDiagnostic(
                accountID: account.id,
                status: .scanned,
                scannedTranscriptCount: transcriptURLs.count,
                malformedLineCount: malformedLineCount
            ),
            transcriptURLs.map { $0.url.path }
        )
    }

    private func transcriptURLs(under root: URL, now: Date) -> [TranscriptCandidate]? {
        guard let enumerator = configuration.fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        let oldestAllowed = now.addingTimeInterval(-configuration.maxTranscriptAge)
        var found: [TranscriptCandidate] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  !url.pathComponents.contains("subagents"),
                  let values = try? url.resourceValues(
                      forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
                  ),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  let fileSize = values.fileSize,
                  modified >= oldestAllowed else {
                continue
            }
            found.append(
                TranscriptCandidate(
                    url: url,
                    modificationDate: modified,
                    fileSize: fileSize
                )
            )
        }

        let sorted = found.sorted {
            if $0.modificationDate != $1.modificationDate {
                return $0.modificationDate > $1.modificationDate
            }
            return $0.url.path < $1.url.path
        }
        return Array(sorted.prefix(configuration.maxTranscriptsPerProfile))
    }

    private func parsedTranscript(for transcript: TranscriptCandidate) -> ParsedTranscript {
        let path = transcript.url.path
        if let cached = transcriptCache[path],
           cached.modificationDate == transcript.modificationDate,
           cached.fileSize == transcript.fileSize {
            return cached.parsed
        }

        let parsed = parseTranscript(transcript)
        transcriptCache[path] = TranscriptCacheEntry(
            modificationDate: transcript.modificationDate,
            fileSize: transcript.fileSize,
            parsed: parsed
        )
        return parsed
    }

    private func parseTranscript(_ transcript: TranscriptCandidate) -> ParsedTranscript {
        guard let read = readTranscript(at: transcript.url) else {
            return ParsedTranscript(observations: [], malformedLineCount: 0)
        }

        let fallbackSessionID = transcript.url.deletingPathExtension().lastPathComponent
        var observations: [String: Observation] = [:]
        var malformedLineCount = 0

        for (index, line) in read.lines.enumerated() {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // The first line of a bounded tail can start mid-record.
                if !(read.wasTruncated && index == 0) {
                    malformedLineCount += 1
                }
                continue
            }
            guard let message = json["message"] as? [String: Any],
                  let rawModel = message["model"] as? String else {
                continue
            }

            let model = CostTracker.normalizeClaudeModel(rawModel)
            guard model.hasPrefix("claude-fable-5") else { continue }

            let sourceSessionID = nonEmptyString(json["sessionId"]) ?? fallbackSessionID
            let parsedTimestamp = nonEmptyString(json["timestamp"]).flatMap(FlexibleISO8601.date(from:))
            let timestamp = parsedTimestamp ?? transcript.modificationDate
            let isIncomplete = read.wasTruncated
                || parsedTimestamp == nil
                || nonEmptyString(json["sessionId"]) == nil
            let stopReason = nonEmptyString(message["stop_reason"])
            let observation = Observation(
                sourceSessionID: sourceSessionID,
                model: model,
                firstObservedAt: timestamp,
                lastObservedAt: timestamp,
                lastStopReason: stopReason,
                isIncomplete: isIncomplete
            )

            if var existing = observations[sourceSessionID] {
                existing.merge(observation)
                observations[sourceSessionID] = existing
            } else {
                observations[sourceSessionID] = observation
            }
        }

        if malformedLineCount > 0 {
            for sessionID in Array(observations.keys) {
                observations[sessionID]?.isIncomplete = true
            }
        }

        return ParsedTranscript(
            observations: Array(observations.values),
            malformedLineCount: malformedLineCount
        )
    }

    private func readTranscript(at url: URL) -> TranscriptRead? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let byteLimit = UInt64(configuration.maxBytesPerTranscript)
        let start = size > byteLimit ? size - byteLimit : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        // Lossy decoding keeps a bounded tail usable when it starts midway
        // through a multi-byte scalar.
        // swiftlint:disable:next optional_data_string_conversion
        let content = String(decoding: data, as: UTF8.self)
        return TranscriptRead(
            lines: content.split(separator: "\n", omittingEmptySubsequences: true),
            wasTruncated: start > 0
        )
    }

    private func state(for observation: Observation, now: Date) -> ClaudeFableSession.State {
        let age = max(0, now.timeIntervalSince(observation.lastObservedAt))
        if age <= configuration.activeWindow {
            return .active
        }
        if !observation.isIncomplete,
           let stopReason = observation.lastStopReason,
           ClaudeFableSessionPolicy.terminalStopReasons.contains(stopReason) {
            return .completed
        }
        return .unknown
    }

    private func isReadableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return configuration.fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && configuration.fileManager.isReadableFile(atPath: url.path)
    }

    nonisolated private static func expandedPath(
        _ rawPath: String,
        realHomeDirectory: String
    ) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" {
            return realHomeDirectory
        }
        if trimmed.hasPrefix("~/") {
            return (realHomeDirectory as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
        }
        return (trimmed as NSString).standardizingPath
    }

    nonisolated private static func isNewer(
        _ lhs: ClaudeFableSession,
        _ rhs: ClaudeFableSession
    ) -> Bool {
        if lhs.lastObservedAt != rhs.lastObservedAt {
            return lhs.lastObservedAt > rhs.lastObservedAt
        }
        return lhs.id < rhs.id
    }

    nonisolated private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
final class ClaudeFableSessionStore {
    private let userDefaults: UserDefaults
    private let storageKey: String
    private let retention: TimeInterval
    private let activeWindow: TimeInterval
    private let maxRecords: Int

    init(
        userDefaults: UserDefaults? = nil,
        storageKey: String = StorageKeys.claudeFableSessions,
        retention: TimeInterval = ClaudeFableSessionPolicy.retention,
        activeWindow: TimeInterval = ClaudeFableSessionPolicy.activeWindow,
        maxRecords: Int = 500
    ) {
        self.userDefaults = userDefaults
            ?? UserDefaults(suiteName: SharedMetricsStore.appGroupIdentifier)
            ?? .standard
        self.storageKey = storageKey
        self.retention = retention
        self.activeWindow = activeWindow
        self.maxRecords = max(1, maxRecords)
    }

    func load(now: Date = Date()) -> [ClaudeFableSession] {
        guard let data = userDefaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ClaudeFableSession].self, from: data) else {
            return []
        }
        var byID: [String: ClaudeFableSession] = [:]
        for session in decoded.map({ aged($0, now: now) }) {
            if let existing = byID[session.id] {
                byID[session.id] = merged(existing, session)
            } else {
                byID[session.id] = session
            }
        }
        return retained(Array(byID.values), now: now)
    }

    @discardableResult
    func merge(_ observed: [ClaudeFableSession], now: Date = Date()) -> [ClaudeFableSession] {
        var byID: [String: ClaudeFableSession] = [:]
        for session in load(now: now) {
            byID[session.id] = session
        }

        for session in observed {
            let current = aged(session, now: now)
            if let existing = byID[current.id] {
                byID[current.id] = merged(existing, current)
            } else {
                byID[current.id] = current
            }
        }

        let sessions = retained(Array(byID.values), now: now)
        save(sessions)
        return sessions
    }

    private func merged(
        _ existing: ClaudeFableSession,
        _ observed: ClaudeFableSession
    ) -> ClaudeFableSession {
        ClaudeFableSession(
            sourceSessionID: observed.sourceSessionID,
            accountID: observed.accountID,
            accountName: observed.accountName,
            model: observed.lastObservedAt >= existing.lastObservedAt ? observed.model : existing.model,
            firstObservedAt: min(existing.firstObservedAt, observed.firstObservedAt),
            lastObservedAt: max(existing.lastObservedAt, observed.lastObservedAt),
            state: observed.lastObservedAt >= existing.lastObservedAt ? observed.state : existing.state
        )
    }

    private func aged(_ session: ClaudeFableSession, now: Date) -> ClaudeFableSession {
        guard session.state == .active,
              now.timeIntervalSince(session.lastObservedAt) > activeWindow else {
            return session
        }
        return ClaudeFableSession(
            sourceSessionID: session.sourceSessionID,
            accountID: session.accountID,
            accountName: session.accountName,
            model: session.model,
            firstObservedAt: session.firstObservedAt,
            lastObservedAt: session.lastObservedAt,
            state: .unknown
        )
    }

    private func retained(
        _ sessions: [ClaudeFableSession],
        now: Date
    ) -> [ClaudeFableSession] {
        let cutoff = now.addingTimeInterval(-retention)
        let sorted = sessions
            .filter { $0.lastObservedAt >= cutoff }
            .sorted {
                if $0.lastObservedAt != $1.lastObservedAt {
                    return $0.lastObservedAt > $1.lastObservedAt
                }
                return $0.id < $1.id
            }
        return Array(sorted.prefix(maxRecords))
    }

    private func save(_ sessions: [ClaudeFableSession]) {
        do {
            let data = try JSONEncoder().encode(sessions)
            guard userDefaults.data(forKey: storageKey) != data else { return }
            userDefaults.set(data, forKey: storageKey)
        } catch {
            AppLog.storage.error(
                "Failed to persist Fable session metadata: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

@MainActor
protocol ClaudeFableSessionTracking: AnyObject {
    func scheduleRefresh(accounts: [ClaudeCodeAccount])
}

/// Publishes persisted session metadata for later dashboard and CLI surfaces.
/// Refresh orchestration lives in `UsageDataManager`; scanning stays off the
/// main actor inside `ClaudeFableSessionScanner`.
@MainActor
final class ClaudeFableSessionTracker: ObservableObject, ClaudeFableSessionTracking {
    static let shared = ClaudeFableSessionTracker()

    @Published private(set) var sessions: [ClaudeFableSession]
    @Published private(set) var diagnostics: [UUID: ClaudeFableProfileDiagnostic] = [:]

    private let scanner: ClaudeFableSessionScanner
    private let store: ClaudeFableSessionStore
    private var refreshTask: Task<Void, Never>?

    init(
        scanner: ClaudeFableSessionScanner? = nil,
        store: ClaudeFableSessionStore? = nil
    ) {
        let resolvedStore = store ?? ClaudeFableSessionStore()
        self.scanner = scanner ?? ClaudeFableSessionScanner()
        self.store = resolvedStore
        sessions = resolvedStore.load()
    }

    func scheduleRefresh(accounts: [ClaudeCodeAccount]) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let result = await scanner.scan(accounts: accounts)
            guard !Task.isCancelled else {
                refreshTask = nil
                return
            }
            sessions = store.merge(result.sessions)
            diagnostics = result.diagnostics
            refreshTask = nil
        }
    }
}
