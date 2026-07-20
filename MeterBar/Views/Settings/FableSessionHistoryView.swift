import SwiftUI

struct FableSessionHistoryModel: Equatable {
    let active: [ClaudeFableSession]
    let recent: [ClaudeFableSession]
    let unavailableProfileCount: Int
    let malformedLineCount: Int

    init(
        sessions: [ClaudeFableSession],
        diagnostics: [UUID: ClaudeFableProfileDiagnostic]
    ) {
        let normalized = ClaudeFableSessionPresentation.normalized(sessions)
        active = normalized.filter { $0.state == .active }
        recent = normalized.filter { $0.state != .active }
        unavailableProfileCount = diagnostics.values.filter { $0.status == .unavailable }.count
        malformedLineCount = diagnostics.values.reduce(0) { $0 + $1.malformedLineCount }
    }
}

struct FableSessionHistoryView: View {
    let model: FableSessionHistoryModel

    init(
        sessions: [ClaudeFableSession],
        diagnostics: [UUID: ClaudeFableProfileDiagnostic] = [:]
    ) {
        model = FableSessionHistoryModel(sessions: sessions, diagnostics: diagnostics)
    }

    var body: some View {
        SettingsPanelSection(
            title: "Fable 5 Sessions",
            systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
            color: MeterBarTheme.claudeAccent
        ) {
            if model.active.isEmpty, model.recent.isEmpty {
                EmptyStateCard(
                    systemImage: "text.page.badge.magnifyingglass",
                    title: "No Fable 5 activity found",
                    message: "Run a Fable 5 session, then refresh Claude Code to populate this history."
                )
            } else {
                FableSessionGroup(title: "Active", sessions: model.active)
                FableSessionGroup(title: "Recent", sessions: model.recent)
            }

            if model.unavailableProfileCount > 0 || model.malformedLineCount > 0 {
                SettingsDivider()
                FableSessionDiagnosticNotice(model: model)
            }
        }
    }
}

private struct FableSessionGroup: View {
    let title: String
    let sessions: [ClaudeFableSession]

    var body: some View {
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(title) (\(sessions.count))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 {
                        SettingsDivider()
                    }
                    FableSessionRow(session: session)
                }
            }
        }
    }
}

private struct FableSessionRow: View {
    let session: ClaudeFableSession

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.accountName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(session.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 5) {
                MeterBarChip(
                    session.state.displayName,
                    systemImage: session.state.systemImage,
                    tint: session.state.tint
                )
                Text("Last seen \(session.lastObservedAt, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(
                    "\(session.firstObservedAt.formatted(date: .abbreviated, time: .shortened))"
                        + " – \(session.lastObservedAt.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(session.accountName), \(session.model), \(session.state.displayName), "
                + "last seen \(session.lastObservedAt.formatted(date: .abbreviated, time: .shortened))"
        )
    }
}

private struct FableSessionDiagnosticNotice: View {
    let model: FableSessionHistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if model.unavailableProfileCount > 0 {
                Text(
                    "\(model.unavailableProfileCount) Claude "
                        + "\(model.unavailableProfileCount == 1 ? "profile was" : "profiles were") unavailable."
                )
            }
            if model.malformedLineCount > 0 {
                Text(
                    "\(model.malformedLineCount) malformed transcript "
                        + "\(model.malformedLineCount == 1 ? "record was" : "records were") ignored."
                )
            }
        }
        .font(.caption)
        .foregroundStyle(MeterBarTheme.warning)
        .accessibilityElement(children: .combine)
    }
}

private extension ClaudeFableSession.State {
    var displayName: String {
        switch self {
        case .active: "Active"
        case .completed: "Completed"
        case .unknown: "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .active: "circle.fill"
        case .completed: "checkmark.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .active: MeterBarTheme.success
        case .completed: MeterBarTheme.claudeAccent
        case .unknown: MeterBarTheme.warning
        }
    }
}
