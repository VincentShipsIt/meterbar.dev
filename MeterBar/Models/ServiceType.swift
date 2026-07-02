import Foundation

enum ServiceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode = "Claude Code"
    case codexCli = "Codex CLI"
    case cursor = "Cursor"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCli: return "OpenAI Codex"
        case .cursor: return "Cursor"
        }
    }

    var iconName: String {
        switch self {
        case .claudeCode: return "terminal"
        case .codexCli: return "terminal.fill"
        case .cursor: return "cursorarrow.click"
        }
    }
}
