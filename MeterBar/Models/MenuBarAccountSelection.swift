import Foundation
import MeterBarShared

// MARK: - MenuBarAccountDisplayMode

/// How the menu bar presents MeterBar's tracked accounts (issue #266).
nonisolated enum MenuBarAccountDisplayMode: String, CaseIterable, Identifiable, Sendable {
    /// One status item that follows Auto/pin selection across every account.
    /// This is the pre-#266 behavior and stays the default, so an existing
    /// installation that never opts in keeps the menu bar it had before.
    case single
    /// One status item per explicitly selected account, capped by
    /// `MenuBarStatusItemPlanner.maximumConcurrentItems`.
    case perAccount
    /// One status item bound to a chosen account, with an in-menu switcher.
    case merged

    // MARK: Internal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .single: "Single Item"
        case .perAccount: "One Per Account"
        case .merged: "Merged With Switcher"
        }
    }
}

// MARK: - MenuBarAccountKey

/// Stable `<service>:<accountID>` identity for one tracked account. Persisted in
/// user defaults, so the format must not change without a migration.
nonisolated enum MenuBarAccountKey {
    static func make(service: ServiceType, accountID: UUID) -> String {
        "\(service.rawValue):\(accountID.uuidString)"
    }
}

// MARK: - MenuBarAccountLabel

/// The single sanitizing seam for account names on their way to the menu bar.
///
/// Account names are user-supplied and are frequently pasted config-directory
/// paths (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`). Rendering one verbatim would both
/// blow out the menu-bar width and leak a local filesystem path onto a shared
/// screen, so every label is reduced to its last path component, stripped of
/// control characters, and length-capped before it can be displayed.
nonisolated enum MenuBarAccountLabel {
    /// Menu-bar width is shared with every other app's items; 18 characters is
    /// roughly the widest label that still leaves room for a percentage.
    static let maximumLength = 18
    static let fallbackName = "Account"
    static let fallbackBadge = "•"

    static func displayName(for rawName: String) -> String {
        let lastComponent = rawName.split(separator: "/").last.map(String.init) ?? rawName
        let flattened = String(lastComponent.unicodeScalars.map { scalar -> Character in
            let isUnsafe = CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
            return isUnsafe ? " " : Character(scalar)
        })
        let collapsed = flattened.split(separator: " ").joined(separator: " ")
        guard !collapsed.isEmpty else { return fallbackName }
        guard collapsed.count > maximumLength else { return collapsed }
        return String(collapsed.prefix(maximumLength - 1)) + "…"
    }

    /// Compact affordance that keeps two same-provider status items from being
    /// visually identical: up to two initials from the sanitized name.
    static func badge(for rawName: String) -> String {
        let initials = displayName(for: rawName)
            .split(separator: " ")
            .prefix(2)
            .compactMap { word in word.first { $0.isLetter || $0.isNumber } }
        guard !initials.isEmpty else { return fallbackBadge }
        return String(initials).uppercased()
    }
}

// MARK: - MenuBarAccountIdentity

/// One account the menu bar can show, already sanitized for display.
nonisolated struct MenuBarAccountIdentity: Equatable, Identifiable, Sendable {
    // MARK: Lifecycle

    init(
        key: String,
        service: ServiceType,
        accountID: UUID,
        displayName: String,
        badge: String,
        isEnabled: Bool
    ) {
        self.key = key
        self.service = service
        self.accountID = accountID
        self.displayName = displayName
        self.badge = badge
        self.isEnabled = isEnabled
    }

    // MARK: Internal

    let key: String
    let service: ServiceType
    let accountID: UUID
    /// Sanitized and length-capped — safe to render in the menu bar or a menu.
    let displayName: String
    /// 1–2 character distinguishing affordance.
    let badge: String
    /// False when the account itself is disabled *or* its provider is untracked;
    /// either way it must claim no status item.
    let isEnabled: Bool

    var id: String { key }
}

// MARK: - MenuBarAccountCatalog

/// Builds the menu bar's view of every tracked Claude and Codex account.
///
/// Only these two providers support multiple accounts today; Cursor, OpenRouter,
/// and Grok remain single-account and are served by the aggregate status item.
nonisolated enum MenuBarAccountCatalog {
    static func identities(
        claudeAccounts: [ClaudeCodeAccount],
        codexAccounts: [CodexAccount],
        enabledServices: Set<ServiceType>
    ) -> [MenuBarAccountIdentity] {
        let claude = claudeAccounts.map { account in
            identity(
                service: .claudeCode,
                accountID: account.id,
                rawName: account.name,
                isEnabled: account.isEnabled && enabledServices.contains(.claudeCode)
            )
        }
        let codex = codexAccounts.map { account in
            identity(
                service: .codexCli,
                accountID: account.id,
                rawName: account.name,
                isEnabled: account.isEnabled && enabledServices.contains(.codexCli)
            )
        }
        return claude + codex
    }

    // MARK: Private

    private static func identity(
        service: ServiceType,
        accountID: UUID,
        rawName: String,
        isEnabled: Bool
    ) -> MenuBarAccountIdentity {
        MenuBarAccountIdentity(
            key: MenuBarAccountKey.make(service: service, accountID: accountID),
            service: service,
            accountID: accountID,
            displayName: MenuBarAccountLabel.displayName(for: rawName),
            badge: MenuBarAccountLabel.badge(for: rawName),
            isEnabled: isEnabled
        )
    }
}
