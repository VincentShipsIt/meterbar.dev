import Foundation

enum ServiceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude = "Claude"
    case claudeCode = "Claude Code"
    case openai = "OpenAI"
    case codexCli = "Codex CLI"
    case cursor = "Cursor"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude API"
        case .claudeCode: return "Claude Code"
        case .openai: return "OpenAI"
        case .codexCli: return "OpenAI Codex"
        case .cursor: return "Cursor"
        }
    }

    var iconName: String {
        switch self {
        case .claude: return "sparkles"
        case .claudeCode: return "terminal"
        case .openai: return "brain"
        case .codexCli: return "terminal.fill"
        case .cursor: return "cursorarrow.click"
        }
    }
}
