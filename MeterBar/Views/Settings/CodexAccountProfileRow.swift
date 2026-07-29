import AppKit
import MeterBarShared
import SwiftUI

// MARK: - CodexAccountProfileDraft

nonisolated struct CodexAccountProfileSave: Equatable, Sendable {
    let name: String
    /// `nil` means the directory did not change. An empty string is meaningful
    /// for the default account: clear its override and resume CODEX_HOME fallback.
    let homeDirectory: String?
}

/// Testable draft state for a SwiftUI account row.
///
/// Store publications can arrive while a field is focused (for example after
/// toggling enablement or completing an auth check). Reconciliation updates only
/// pristine fields so those publications never erase an in-progress label edit.
nonisolated struct CodexAccountProfileDraft: Equatable, Sendable {
    var name: String
    var homeDirectory: String

    init(account: CodexAccount, resolvedHomeDirectory: String) {
        name = account.name
        homeDirectory = resolvedHomeDirectory
    }

    mutating func reconcile(
        from previousAccount: CodexAccount,
        previousResolvedHomeDirectory: String,
        to updatedAccount: CodexAccount,
        updatedResolvedHomeDirectory: String
    ) {
        if name == previousAccount.name {
            name = updatedAccount.name
        }
        if homeDirectory == previousResolvedHomeDirectory {
            homeDirectory = updatedResolvedHomeDirectory
        }
    }

    mutating func commit(
        _ save: CodexAccountProfileSave,
        committedResolvedHomeDirectory: String
    ) {
        name = save.name
        if save.homeDirectory != nil {
            homeDirectory = committedResolvedHomeDirectory
        }
    }

    func savePayload(
        for account: CodexAccount,
        resolvedHomeDirectory: String
    ) -> CodexAccountProfileSave? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHomeDirectory = homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              account.isDefault || !trimmedHomeDirectory.isEmpty else {
            return nil
        }

        let nameChanged = trimmedName != account.name
        let directoryChanged = trimmedHomeDirectory != resolvedHomeDirectory
        guard nameChanged || directoryChanged else { return nil }

        return CodexAccountProfileSave(
            name: trimmedName,
            homeDirectory: directoryChanged ? trimmedHomeDirectory : nil
        )
    }
}

// MARK: - CodexAccountAuthenticationState

nonisolated enum CodexAccountAuthenticationState: Equatable, Sendable {
    case checking
    case authenticated
    case loginRequired
    case disabled

    var title: String {
        switch self {
        case .checking: "Checking…"
        case .authenticated: "Authenticated"
        case .loginRequired: "Login required"
        case .disabled: "Disabled"
        }
    }

    var accessibilityValue: String {
        switch self {
        case .checking: "Checking the configured auth file"
        case .authenticated: "A non-expired Codex access token is available"
        case .loginRequired: "No usable Codex access token is available"
        case .disabled: "This account is not included in tracking"
        }
    }
}

// MARK: - CodexAccountProfileRow

/// One editable Codex account row (label + CODEX_HOME + enable / save / delete).
/// The fixed default id remains an internal migration sentinel, but its location
/// and tracking state have the same user-facing semantics as custom profiles.
struct CodexAccountProfileRow: View {
    // MARK: Lifecycle

    init(
        account: CodexAccount,
        canDisable: Bool,
        canRemove: Bool,
        onEnabledChange: @escaping (Bool) -> Void,
        onSave: @escaping (String, String?) -> Void,
        onRemove: @escaping () -> Void,
        connectionCheck: @escaping (CodexAccount) async -> Bool = {
            await CodexCliLocalService.shared.canAccess(account: $0)
        }
    ) {
        self.account = account
        self.canDisable = canDisable
        self.canRemove = canRemove
        self.onEnabledChange = onEnabledChange
        self.onSave = onSave
        self.onRemove = onRemove
        self.connectionCheck = connectionCheck
        _draft = State(initialValue: CodexAccountProfileDraft(
            account: account,
            resolvedHomeDirectory: Self.resolvedHomeDirectory(for: account)
        ))
        _authenticationState = State(initialValue: account.isEnabled ? .checking : .disabled)
    }

    // MARK: Internal

    let account: CodexAccount
    let canDisable: Bool
    let canRemove: Bool
    let onEnabledChange: (Bool) -> Void
    let onSave: (String, String?) -> Void
    let onRemove: () -> Void
    let connectionCheck: (CodexAccount) async -> Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: account.isDefault ? "person.crop.circle" : "person.crop.circle.badge.plus")
                .foregroundStyle(MeterBarTheme.codexAccent)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    accountFieldLabel("Account name")

                    TextField("Account label", text: $draft.name)
                        .settingsInput(width: AccountProfileRowMetrics.fieldWidth)
                        .accessibilityLabel("Account name for \(account.name)")
                        .onSubmit(saveChanges)

                    MeterBarChip(
                        account.isDefault ? "Default" : "Profile",
                        tint: account.isDefault ? MeterBarTheme.appAccent : MeterBarTheme.codexAccent,
                        style: .glass
                    )

                    MeterBarChip(
                        authenticationState.title,
                        tint: authenticationTint,
                        style: .glass
                    )
                    .accessibilityLabel("Authentication status for \(account.name)")
                    .accessibilityValue(authenticationState.accessibilityValue)
                }

                HStack(spacing: 8) {
                    accountFieldLabel("CODEX_HOME")

                    TextField("Codex home directory", text: $draft.homeDirectory)
                        .settingsInput(width: AccountProfileRowMetrics.fieldWidth)
                        .accessibilityLabel("CODEX_HOME for \(account.name)")
                        .onSubmit(saveChanges)

                    Button {
                        chooseHomeDirectory()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Choose CODEX_HOME for \(account.name)")
                    .help("Choose CODEX_HOME")
                }

                if account.isDefault {
                    Text("Defaults to ~/.codex or $CODEX_HOME; clear the field to restore that default.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, AccountProfileRowMetrics.labelWidth + 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Toggle("Enabled", isOn: Binding(
                    get: { account.isEnabled },
                    set: onEnabledChange
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(account.isEnabled && !canDisable)
                .accessibilityLabel("Track \(account.name)")
                .help(enablementHelp)

                Button(action: saveChanges) {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(width: AccountProfileRowMetrics.actionWidth)
                .disabled(savePayload == nil)
                .accessibilityLabel("Save changes for \(account.name)")
                .help("Save account changes")

                if !account.isDefault {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(width: AccountProfileRowMetrics.actionWidth)
                    .disabled(!canRemove)
                    .accessibilityLabel("Delete \(account.name)")
                    .help(deleteHelp)
                } else {
                    Color.clear
                        .frame(width: AccountProfileRowMetrics.actionWidth, height: 1)
                        .accessibilityHidden(true)
                }
            }
            .fixedSize()
        }
        .padding(.vertical, MeterBarTheme.Spacing.md)
        .onChange(of: account) { previousAccount, updatedAccount in
            draft.reconcile(
                from: previousAccount,
                previousResolvedHomeDirectory: Self.resolvedHomeDirectory(for: previousAccount),
                to: updatedAccount,
                updatedResolvedHomeDirectory: Self.resolvedHomeDirectory(for: updatedAccount)
            )
        }
        .task(id: connectionProbeID) {
            await refreshAuthenticationState()
        }
        .confirmationDialog(
            "Delete \(account.name)?",
            isPresented: $showingDeleteConfirmation
        ) {
            Button("Delete Account", role: .destructive, action: onRemove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MeterBar will stop tracking this CODEX_HOME. Files and Codex login data are not deleted.")
        }
    }

    // MARK: Private

    @State private var draft: CodexAccountProfileDraft
    @State private var authenticationState: CodexAccountAuthenticationState
    @State private var showingDeleteConfirmation = false

    private var resolvedHomeDirectory: String {
        Self.resolvedHomeDirectory(for: account)
    }

    private var savePayload: CodexAccountProfileSave? {
        draft.savePayload(for: account, resolvedHomeDirectory: resolvedHomeDirectory)
    }

    private var authenticationTint: Color {
        switch authenticationState {
        case .authenticated: MeterBarTheme.success
        case .loginRequired: MeterBarTheme.warning
        case .checking, .disabled: .secondary
        }
    }

    private var enablementHelp: String {
        if account.isEnabled, !canDisable {
            return "Enable another Codex account before disabling this one"
        }
        return account.isEnabled ? "Disable account" : "Enable account"
    }

    private var deleteHelp: String {
        canRemove ? "Delete account" : "Enable another Codex account before deleting this one"
    }

    private var connectionProbeID: CodexConnectionProbeID {
        CodexConnectionProbeID(
            accountID: account.id,
            homeDirectory: account.homeDirectory,
            isEnabled: account.isEnabled
        )
    }

    private func saveChanges() {
        guard let savePayload else { return }
        onSave(savePayload.name, savePayload.homeDirectory)
        var committedAccount = account
        committedAccount.name = savePayload.name
        if let homeDirectory = savePayload.homeDirectory {
            let trimmedDirectory = homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            committedAccount.homeDirectory = trimmedDirectory.isEmpty
                ? nil
                : (trimmedDirectory as NSString).standardizingPath
        }
        draft.commit(
            savePayload,
            committedResolvedHomeDirectory: Self.resolvedHomeDirectory(for: committedAccount)
        )
    }

    private func accountFieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .frame(width: AccountProfileRowMetrics.labelWidth, alignment: .leading)
    }

    private static func resolvedHomeDirectory(for account: CodexAccount) -> String {
        CodexHomeDirectory.path(for: account)
    }

    private func chooseHomeDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use"

        if panel.runModal() == .OK, let url = panel.url {
            draft.homeDirectory = url.path
        }
    }

    private func refreshAuthenticationState() async {
        guard account.isEnabled else {
            authenticationState = .disabled
            return
        }
        authenticationState = .checking
        let isAuthenticated = await connectionCheck(account)
        guard !Task.isCancelled else { return }
        authenticationState = isAuthenticated ? .authenticated : .loginRequired
    }
}

private struct CodexConnectionProbeID: Equatable {
    let accountID: UUID
    let homeDirectory: String?
    let isEnabled: Bool
}
