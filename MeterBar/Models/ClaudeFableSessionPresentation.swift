import Foundation

nonisolated enum ClaudeFableSessionPresentation {
    static func normalized(_ sessions: [ClaudeFableSession]) -> [ClaudeFableSession] {
        var byID: [String: ClaudeFableSession] = [:]
        for session in sessions {
            guard let existing = byID[session.id] else {
                byID[session.id] = session
                continue
            }
            byID[session.id] = merged(existing, session)
        }

        return byID.values.sorted {
            if $0.lastObservedAt != $1.lastObservedAt {
                return $0.lastObservedAt > $1.lastObservedAt
            }
            return $0.id < $1.id
        }
    }

    static func merged(
        _ existing: ClaudeFableSession,
        _ observed: ClaudeFableSession
    ) -> ClaudeFableSession {
        let latest = observed.lastObservedAt >= existing.lastObservedAt ? observed : existing
        return ClaudeFableSession(
            sourceSessionID: latest.sourceSessionID,
            accountID: latest.accountID,
            accountName: latest.accountName,
            model: latest.model,
            firstObservedAt: min(existing.firstObservedAt, observed.firstObservedAt),
            lastObservedAt: max(existing.lastObservedAt, observed.lastObservedAt),
            state: latest.state
        )
    }
}

/// Compact account-scoped activity shown on the shared Claude provider card.
///
/// The full history remains in Settings. This projection deliberately keeps
/// only the most relevant session so the popover and dashboard can answer the
/// immediate question — "is Fable active on this account?" — without exposing
/// transcript content or crowding the quota card.
nonisolated struct FableSessionCardActivity: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case active
        case recent
        case noActivity
    }

    let session: ClaudeFableSession?

    static func make(
        accountID: UUID,
        sessions: [ClaudeFableSession],
        now: Date = Date()
    ) -> FableSessionCardActivity {
        let accountSessions = ClaudeFableSessionPresentation.normalized(sessions)
            .filter { $0.accountID == accountID }
        return make(normalizedAccountSessions: accountSessions, now: now)
    }

    static func byAccount(
        sessions: [ClaudeFableSession],
        now: Date = Date()
    ) -> [UUID: FableSessionCardActivity] {
        Dictionary(grouping: ClaudeFableSessionPresentation.normalized(sessions), by: \.accountID)
            .mapValues { make(normalizedAccountSessions: $0, now: now) }
    }

    private static func make(
        normalizedAccountSessions accountSessions: [ClaudeFableSession],
        now: Date
    ) -> FableSessionCardActivity {
        let active = accountSessions.first {
            $0.state == .active
                && now.timeIntervalSince($0.lastObservedAt) <= ClaudeFableSessionPolicy.activeWindow
        }
        return FableSessionCardActivity(session: active ?? accountSessions.first)
    }

    func status(now: Date = Date()) -> Status {
        guard let session else { return .noActivity }
        guard session.state == .active,
              now.timeIntervalSince(session.lastObservedAt) <= ClaudeFableSessionPolicy.activeWindow else {
            return .recent
        }
        return .active
    }
}

/// Human-readable output shared by the CLI implementation and contract tests.
nonisolated public enum FableSessionsTextFormatter {
    public static func format(_ sessions: [ClaudeFableSession]) -> String {
        let sessions = ClaudeFableSessionPresentation.normalized(sessions)
        guard !sessions.isEmpty else {
            return """
            No Fable 5 sessions found.
            Open MeterBar and refresh Claude Code after running a Fable 5 session.
            """
        }

        let active = sessions.filter { $0.state == .active }
        let recent = sessions.filter { $0.state != .active }
        var lines = [
            "MeterBar Fable 5 Sessions",
            "\(active.count) active · \(recent.count) recent",
        ]
        append(active, heading: "Active", to: &lines)
        append(recent, heading: "Recent", to: &lines)
        return lines.joined(separator: "\n")
    }

    private static func append(
        _ sessions: [ClaudeFableSession],
        heading: String,
        to lines: inout [String]
    ) {
        guard !sessions.isEmpty else { return }
        lines.append("")
        lines.append(heading)
        for session in sessions {
            lines.append("  \(session.accountName) · \(session.model) · \(session.state.rawValue)")
            lines.append(
                "    first \(timestamp(session.firstObservedAt)) · last \(timestamp(session.lastObservedAt))"
            )
        }
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
