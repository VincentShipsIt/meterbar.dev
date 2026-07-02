import Foundation

/// The subscription providers MeterBar tracks. The admin-API providers
/// (`Claude`/`OpenAI` raw values) were removed with the admin-key feature;
/// tolerant cache decoding skips their entries in older on-disk payloads.
public enum ServiceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode = "Claude Code"
    case codexCli = "Codex CLI"
    case cursor = "Cursor"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCli: return "OpenAI Codex"
        case .cursor: return "Cursor"
        }
    }

    /// SF Symbol name used by the app UI.
    public var iconName: String {
        switch self {
        case .claudeCode: return "terminal"
        case .codexCli: return "terminal.fill"
        case .cursor: return "cursorarrow.click"
        }
    }

    /// Asset-catalog image name used by the widget extension, which ships
    /// provider logos instead of SF Symbols.
    public var assetName: String {
        switch self {
        case .claudeCode: return "ClaudeIcon"
        case .codexCli: return "CodexIcon"
        case .cursor: return "CursorIcon"
        }
    }

    /// Stable display ordering (most-used services first).
    public var sortOrder: Int {
        switch self {
        case .claudeCode: return 0
        case .codexCli: return 1
        case .cursor: return 2
        }
    }
}
