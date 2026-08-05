import Foundation
import MeterBarShared
import SwiftUI

// MARK: - Save / draft (shared by Claude, Codex, and Grok profile rows)

/// Mutation emitted when the user saves a multi-account profile row.
///
/// `path` is `nil` when the directory field did not change. An empty string is
/// meaningful for default profiles: clear the override and resume the provider
/// env/default fallback (`~/.claude`, `$CODEX_HOME`, `$GROK_HOME`, …).
nonisolated struct ProviderAccountProfileSave: Equatable, Sendable {
    let name: String
    let path: String?
}

/// Testable draft state for one provider-account Settings row.
///
/// Store publications can arrive while a field is focused (enable toggles,
/// auth probes). Reconciliation only updates pristine fields so those
/// publications never erase an in-progress label edit.
nonisolated struct ProviderAccountProfileDraft: Equatable, Sendable {
    var name: String
    var path: String

    init(name: String, resolvedPath: String) {
        self.name = name
        self.path = resolvedPath
    }

    mutating func reconcile(
        previousName: String,
        previousResolvedPath: String,
        updatedName: String,
        updatedResolvedPath: String
    ) {
        if name == previousName {
            name = updatedName
        }
        if path == previousResolvedPath {
            path = updatedResolvedPath
        }
    }

    mutating func commit(_ save: ProviderAccountProfileSave, committedResolvedPath: String) {
        name = save.name
        if save.path != nil {
            path = committedResolvedPath
        }
    }

    func savePayload(
        currentName: String,
        resolvedPath: String,
        isDefault: Bool
    ) -> ProviderAccountProfileSave? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, isDefault || !trimmedPath.isEmpty else {
            return nil
        }

        let nameChanged = trimmedName != currentName
        let pathChanged = trimmedPath != resolvedPath
        guard nameChanged || pathChanged else { return nil }

        return ProviderAccountProfileSave(
            name: trimmedName,
            path: pathChanged ? trimmedPath : nil
        )
    }
}

// MARK: - Connection presentation (shared StatusPill language)

/// Honest connection states for CLI-backed account rows that probe auth
/// presence without Claude's multi-source auth enum.
nonisolated enum ProviderAccountConnectionState: Equatable, Sendable {
    case checking
    case authenticated
    case loginRequired
    case disabled

    var title: String {
        switch self {
        case .checking: "Checking…"
        case .authenticated: "Connected"
        case .loginRequired: "Login required"
        case .disabled: "Disabled"
        }
    }

    var accessibilityValue: String {
        switch self {
        case .checking: "Checking the configured profile"
        case .authenticated: "A usable login is available for this profile"
        case .loginRequired: "No usable login is available for this profile"
        case .disabled: "This account is not included in tracking"
        }
    }

    var statusPresentation: SettingsStatusPresentation {
        switch self {
        case .checking:
            SettingsStatusPresentation(
                text: title,
                systemImage: "arrow.clockwise",
                tone: .neutral
            )
        case .authenticated:
            SettingsStatusPresentation(
                text: title,
                systemImage: "checkmark.circle.fill",
                tone: .success
            )
        case .loginRequired:
            SettingsStatusPresentation(
                text: title,
                systemImage: "person.crop.circle.badge.exclamationmark",
                tone: .warning
            )
        case .disabled:
            SettingsStatusPresentation(
                text: title,
                systemImage: "pause.circle",
                tone: .neutral
            )
        }
    }

    static func from(isEnabled: Bool, isConnected: Bool) -> ProviderAccountConnectionState {
        guard isEnabled else { return .disabled }
        return isConnected ? .authenticated : .loginRequired
    }
}

// MARK: - Status pill accessibility

/// VoiceOver text for a profile row's status pill.
///
/// The label names the account and the value carries the state, so the pill
/// reads as "Status for Work — No usable login is available for this profile"
/// instead of stopping at the account name. Rows without a richer sentence fall
/// back to the pill's own text, which still beats announcing no value at all.
nonisolated enum ProviderAccountStatusAccessibility {
    static func label(accountName: String) -> String {
        "Status for \(accountName)"
    }

    static func value(_ presentation: SettingsStatusPresentation, detail: String?) -> String {
        detail ?? presentation.text
    }
}

// MARK: - Claude auth actions (only Claude reconnects via Terminal)

enum ProviderAccountAuthActionRoute: Equatable {
    case performRefresh
    case requestReconnectConfirmation
}

/// Presentation and routing for optional per-row auth actions.
///
/// `arrow.clockwise` is exclusive to non-mutating refresh. Reconnect is
/// visibly labeled and always confirmation-gated.
enum ProviderAccountAuthAction: Equatable {
    case refresh
    case reconnect

    var title: String {
        switch self {
        case .refresh: "Refresh"
        case .reconnect: "Reconnect"
        }
    }

    var systemImage: String {
        switch self {
        case .refresh: "arrow.clockwise"
        case .reconnect: "key.horizontal"
        }
    }

    var route: ProviderAccountAuthActionRoute {
        switch self {
        case .refresh: .performRefresh
        case .reconnect: .requestReconnectConfirmation
        }
    }

    var showsVisibleTitle: Bool { self == .reconnect }

    func accessibilityLabel(accountName: String) -> String {
        "\(title) \(accountName)"
    }

    func help(accountName: String) -> String {
        switch self {
        case .refresh:
            "Refresh status and usage for \(accountName)"
        case .reconnect:
            "Log out and sign in again for \(accountName)"
        }
    }
}

enum ProviderAccountReconnectConfirmation {
    static let confirmButtonTitle = "Reconnect"

    static func title(accountName: String) -> String {
        "Reconnect \(accountName)?"
    }

    static func message(accountName: String, providerDisplayName: String) -> String {
        "Terminal will open, log out the \(accountName) \(providerDisplayName) profile, then ask you to sign in again."
    }
}

// MARK: - Layout metrics

enum AccountProfileRowMetrics {
    static let labelWidth: CGFloat = 126
    static let fieldWidth: CGFloat = 280
    static let actionWidth: CGFloat = 28
}

// MARK: - Compatibility aliases (existing tests)

typealias CodexAccountProfileSave = ProviderAccountProfileSave
typealias CodexAccountProfileDraft = ProviderAccountProfileDraft
typealias CodexAccountAuthenticationState = ProviderAccountConnectionState
typealias ClaudeAccountRowAction = ProviderAccountAuthAction
typealias ClaudeAccountRowActionRoute = ProviderAccountAuthActionRoute

enum ClaudeReconnectConfirmation {
    static let confirmButtonTitle = ProviderAccountReconnectConfirmation.confirmButtonTitle

    static func title(for account: ClaudeCodeAccount) -> String {
        ProviderAccountReconnectConfirmation.title(accountName: account.name)
    }

    static func message(for account: ClaudeCodeAccount) -> String {
        ProviderAccountReconnectConfirmation.message(
            accountName: account.name,
            providerDisplayName: ServiceType.claudeCode.shortName
        )
    }
}

extension ProviderAccountProfileSave {
    /// Legacy property name used by Codex tests.
    var homeDirectory: String? { path }
}

extension ProviderAccountProfileDraft {
    init(account: CodexAccount, resolvedHomeDirectory: String) {
        self.init(name: account.name, resolvedPath: resolvedHomeDirectory)
    }

    var homeDirectory: String {
        get { path }
        set { path = newValue }
    }

    mutating func reconcile(
        from previousAccount: CodexAccount,
        previousResolvedHomeDirectory: String,
        to updatedAccount: CodexAccount,
        updatedResolvedHomeDirectory: String
    ) {
        reconcile(
            previousName: previousAccount.name,
            previousResolvedPath: previousResolvedHomeDirectory,
            updatedName: updatedAccount.name,
            updatedResolvedPath: updatedResolvedHomeDirectory
        )
    }

    mutating func commit(
        _ save: ProviderAccountProfileSave,
        committedResolvedHomeDirectory: String
    ) {
        commit(save, committedResolvedPath: committedResolvedHomeDirectory)
    }

    func savePayload(
        for account: CodexAccount,
        resolvedHomeDirectory: String
    ) -> ProviderAccountProfileSave? {
        savePayload(
            currentName: account.name,
            resolvedPath: resolvedHomeDirectory,
            isDefault: account.isDefault
        )
    }
}
