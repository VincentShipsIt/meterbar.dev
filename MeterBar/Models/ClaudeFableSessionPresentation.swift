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
