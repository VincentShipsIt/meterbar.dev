import Foundation

public enum ServiceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude = "Claude"
    case claudeCode = "Claude Code"
    case openai = "OpenAI"
    case codexCli = "Codex CLI"
    case cursor = "Cursor"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude API"
        case .claudeCode: return "Claude Code"
        case .openai: return "OpenAI"
        case .codexCli: return "OpenAI Codex"
        case .cursor: return "Cursor"
        }
    }

    /// SF Symbol name used by the app UI.
    public var iconName: String {
        switch self {
        case .claude: return "sparkles"
        case .claudeCode: return "terminal"
        case .openai: return "brain"
        case .codexCli: return "terminal.fill"
        case .cursor: return "cursorarrow.click"
        }
    }

    /// Asset-catalog image name used by the widget extension, which ships
    /// provider logos instead of SF Symbols.
    public var assetName: String {
        switch self {
        case .claude: return "ClaudeIcon"
        case .claudeCode: return "ClaudeIcon"
        case .openai: return "OpenAIIcon"
        case .codexCli: return "CodexIcon"
        case .cursor: return "CursorIcon"
        }
    }

    /// Stable display ordering (most-used services first).
    public var sortOrder: Int {
        switch self {
        case .claudeCode: return 0
        case .claude: return 1
        case .codexCli: return 2
        case .cursor: return 3
        case .openai: return 4
        }
    }
}
