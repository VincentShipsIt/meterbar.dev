import Foundation

/// The terminal state of a Codex session rollout, mirroring the Claude
/// `TranscriptState` vocabulary so both providers feed the same candidate model.
nonisolated enum CodexRolloutState: Equatable, Sendable {
    /// The session hit a usage window and did not recover afterwards.
    case blocked(reason: WakeBlockReason, blockedAt: Date, resetHint: TranscriptResetParser.Result?)
    /// The session completed or is otherwise not blocked on a usage limit.
    case active
    /// No decisive signal (empty/garbled tail, or no rate-limit data).
    case indeterminate
}

/// What discovery needs from one Codex rollout file.
nonisolated struct CodexRolloutSummary: Equatable, Sendable {
    let sessionID: String
    /// The working directory recorded in `session_meta`, if any.
    let cwd: String?
    /// The `session_meta.source` ("exec", "tui", …), if present.
    let source: String?
    let state: CodexRolloutState
}

/// Classifies a Codex `~/.codex/sessions/**/*.jsonl` rollout into a wake state.
///
/// Codex records usage against structured windows on every `token_count` event:
/// `payload.rate_limits.rate_limit_reached_type` is `null` in normal operation
/// and non-null exactly when a window was hit. That field — not free-text prose
/// (which would false-positive on any session that merely *discusses* rate
/// limits) — is the block signal. A `task_complete` emitted after the hit means
/// the session recovered and is not a wake target, so the classifier clears the
/// blocked state on a later completion, exactly like the Claude classifier
/// clears on successful activity.
nonisolated enum CodexRolloutClassifier {
    /// Mutable state threaded through the linear pass over rollout lines.
    private struct Accumulator {
        var sessionID: String
        var cwd: String?
        var source: String?
        var blocked: (reason: WakeBlockReason, blockedAt: Date, resetHint: TranscriptResetParser.Result?)?
        var sawCompletion = false
    }

    static func classify(fallbackID: String, lines: [String]) -> CodexRolloutSummary {
        var accumulator = Accumulator(sessionID: fallbackID)
        for line in lines {
            guard let object = jsonObject(from: line) else { continue }
            apply(object: object, to: &accumulator)
        }

        let state: CodexRolloutState
        if let blocked = accumulator.blocked, !accumulator.sawCompletion {
            state = .blocked(reason: blocked.reason, blockedAt: blocked.blockedAt, resetHint: blocked.resetHint)
        } else if accumulator.sawCompletion {
            state = .active
        } else {
            state = .indeterminate
        }

        return CodexRolloutSummary(
            sessionID: accumulator.sessionID,
            cwd: accumulator.cwd,
            source: accumulator.source,
            state: state
        )
    }

    /// Fold one decoded rollout line into the accumulator.
    private static func apply(object: [String: Any], to accumulator: inout Accumulator) {
        guard let type = object["type"] as? String else { return }
        let payload = object["payload"] as? [String: Any]

        switch type {
        case "session_meta":
            applyMeta(payload: payload, to: &accumulator)
        case "event_msg":
            applyEvent(payload: payload, timestamp: object["timestamp"] as? String, to: &accumulator)
        default:
            break
        }
    }

    private static func applyMeta(payload: [String: Any]?, to accumulator: inout Accumulator) {
        guard let payload else { return }
        if let id = (payload["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            accumulator.sessionID = id
        }
        if let recordedCwd = (payload["cwd"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !recordedCwd.isEmpty {
            accumulator.cwd = recordedCwd
        }
        accumulator.source = payload["source"] as? String
    }

    private static func applyEvent(payload: [String: Any]?, timestamp: String?, to accumulator: inout Accumulator) {
        guard let payload, let eventType = payload["type"] as? String else { return }
        switch eventType {
        case "token_count":
            if let hit = rateLimitHit(rateLimits: payload["rate_limits"] as? [String: Any], eventTimestamp: timestamp) {
                accumulator.blocked = hit
                accumulator.sawCompletion = false
            }
        case "task_complete":
            // A completed turn after the last recorded hit means the session is
            // no longer stuck on a window.
            accumulator.sawCompletion = true
        default:
            break
        }
    }

    // MARK: - Rate-limit extraction

    /// Interpret a `rate_limits` object. Returns a block only when
    /// `rate_limit_reached_type` is a non-empty string; the window it names
    /// selects both the typed reason and the reset instant.
    private static func rateLimitHit(
        rateLimits: [String: Any]?,
        eventTimestamp: String?
    ) -> (reason: WakeBlockReason, blockedAt: Date, resetHint: TranscriptResetParser.Result?)? {
        guard let rateLimits else { return nil }
        guard let reached = (rateLimits["rate_limit_reached_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !reached.isEmpty else {
            return nil
        }

        // "secondary" is Codex's long (weekly) window; anything else is treated
        // as the short/primary session window.
        let isSecondary = reached.lowercased().contains("secondary")
        let windowKey = isSecondary ? "secondary" : "primary"
        let reason: WakeBlockReason = isSecondary ? .weeklyLimit : .sessionLimit

        let blockedAt = Self.parseTimestamp(eventTimestamp) ?? Date()
        var resetHint: TranscriptResetParser.Result?
        if let window = rateLimits[windowKey] as? [String: Any],
           let resetsAt = Self.epochSeconds(window["resets_at"]) {
            resetHint = TranscriptResetParser.Result(
                resetAt: Date(timeIntervalSince1970: resetsAt),
                timeZoneIdentifier: nil
            )
        }
        return (reason, blockedAt, resetHint)
    }

    // MARK: - Parsing helpers

    private static func jsonObject(from line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Accepts Int/Double/String epoch encodings (rollouts use a bare number).
    private static func epochSeconds(_ value: Any?) -> TimeInterval? {
        switch value {
        case let int as Int: return TimeInterval(int)
        case let double as Double: return double
        case let number as NSNumber: return number.doubleValue
        case let string as String: return TimeInterval(string)
        default: return nil
        }
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }
}
