import Foundation

/// The terminal state of a Claude Code transcript, derived from the *latest
/// decisive event* rather than "does the file contain a rate-limit string".
///
/// A transcript that hit a limit and then made further progress is `.active`,
/// not `.blocked` — the historical limit is stale. Only a limit that is the
/// last decisive event makes a session eligible for wake.
nonisolated enum TranscriptState: Equatable, Sendable {
    /// The last decisive event is a usage limit.
    case blocked(reason: WakeBlockReason, blockedAt: Date, resetHint: TranscriptResetParser.Result?)
    /// The last decisive event is successful assistant/tool activity.
    case active(lastActivityAt: Date)
    /// No decisive event was found (empty/metadata-only transcript).
    case indeterminate
}

/// Metadata a classified transcript exposes to discovery.
nonisolated struct TranscriptSummary: Equatable, Sendable {
    let sessionID: String
    let cwd: String?
    let gitBranch: String?
    /// True when every event line is a subagent/sidechain entry — the whole
    /// transcript belongs to a subagent run (individual sidechain lines are
    /// skipped for classification, not disqualifying).
    let isSidechain: Bool
    let state: TranscriptState
}

/// Classifies raw JSONL transcript lines. Pure and side-effect free so it can
/// run off the main actor and be exhaustively fixture-tested.
nonisolated enum TranscriptClassifier {
    /// A single decoded transcript record, tolerant of the widely varying
    /// Claude Code JSONL schema. Non-object or malformed lines are dropped by
    /// the caller before reaching here.
    private struct Record {
        let type: String?
        let timestamp: Date?
        let isSidechain: Bool
        let isApiError: Bool
        let apiErrorStatus: Int?
        let role: String?
        let text: String
        let sessionID: String?
        let cwd: String?
        let gitBranch: String?

        init?(object: [String: Any]) {
            self.type = object["type"] as? String
            self.timestamp = (object["timestamp"] as? String).flatMap(Record.date(from:))
            self.isSidechain = object["isSidechain"] as? Bool ?? false
            self.isApiError = object["isApiErrorMessage"] as? Bool ?? false
            self.apiErrorStatus = object["apiErrorStatus"] as? Int
            self.sessionID = object["sessionId"] as? String
            self.cwd = object["cwd"] as? String
            self.gitBranch = object["gitBranch"] as? String

            let message = object["message"] as? [String: Any]
            self.role = message?["role"] as? String ?? object["role"] as? String
            self.text = Record.extractText(from: message?["content"] ?? object["content"])
        }

        private static let isoFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        private static let isoFormatterNoFraction: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()

        static func date(from string: String) -> Date? {
            isoFormatter.date(from: string) ?? isoFormatterNoFraction.date(from: string)
        }

        private static func extractText(from content: Any?) -> String {
            if let string = content as? String { return string }
            guard let blocks = content as? [[String: Any]] else { return "" }
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
    }

    /// Classify the ordered JSONL `lines` of one transcript.
    static func classify(sessionID fallbackID: String, lines: [String]) -> TranscriptSummary {
        var resolvedSessionID: String?
        var cwd: String?
        var gitBranch: String?
        var eventCount = 0
        var sidechainEventCount = 0

        var lastDecisiveState: TranscriptState = .indeterminate

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let record = Record(object: object) else {
                // Malformed/truncated JSONL must not crash or poison the scan.
                continue
            }

            let isEvent = isEventRecord(record)
            if isEvent { eventCount += 1 }

            // A subagent (sidechain) line describes a child agent, not this
            // session: it never sets the mainline terminal state and never
            // contributes this session's metadata.
            if record.isSidechain {
                if isEvent { sidechainEventCount += 1 }
                continue
            }

            resolvedSessionID = resolvedSessionID ?? record.sessionID
            if let recordCwd = record.cwd, !recordCwd.isEmpty { cwd = recordCwd }
            if let branch = record.gitBranch, !branch.isEmpty { gitBranch = branch }

            guard let timestamp = record.timestamp else { continue }

            if isBlockingEvent(record) {
                let reason = WakeBlockReason.classify(messageText: record.text)
                let resetHint = TranscriptResetParser.parse(
                    messageText: record.text,
                    eventTimestamp: timestamp
                )
                lastDecisiveState = .blocked(reason: reason, blockedAt: timestamp, resetHint: resetHint)
            } else if isSuccessfulActivity(record) {
                lastDecisiveState = .active(lastActivityAt: timestamp)
            }
        }

        // A transcript is a subagent transcript only when *every* event line is
        // sidechain. A mainline session that merely spawned subagents keeps its
        // own terminal state and stays discoverable.
        let isSubagent = eventCount > 0 && sidechainEventCount == eventCount
        return TranscriptSummary(
            sessionID: resolvedSessionID ?? fallbackID,
            cwd: cwd,
            gitBranch: gitBranch,
            isSidechain: isSubagent,
            state: isSubagent ? .indeterminate : lastDecisiveState
        )
    }

    /// Lines that carry conversational activity — the population the
    /// all-sidechain test is measured against.
    private static func isEventRecord(_ record: Record) -> Bool {
        switch record.type {
        case "assistant", "user", "tool_result":
            return true
        default:
            return false
        }
    }

    /// A 429/limit assistant error is the only kind of blocking event.
    private static func isBlockingEvent(_ record: Record) -> Bool {
        guard record.isApiError else { return false }
        if record.apiErrorStatus == 429 { return true }
        // Some builds omit the status code; fall back to the message body.
        let text = record.text.lowercased()
        return text.contains("limit") && (text.contains("resets") || text.contains("usage") || text.contains("session"))
    }

    /// Real forward progress: a non-error assistant reply, or a tool result /
    /// user turn that lands after a limit and therefore clears it.
    private static func isSuccessfulActivity(_ record: Record) -> Bool {
        if record.isApiError { return false }
        switch record.type {
        case "assistant":
            return record.role == "assistant" || !record.text.isEmpty
        case "user", "tool_result":
            return true
        default:
            return false
        }
    }
}
