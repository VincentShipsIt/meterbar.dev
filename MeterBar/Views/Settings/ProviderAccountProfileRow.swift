import AppKit
import MeterBarShared
import SwiftUI

/// One multi-account provider profile row shared by Claude, Codex, and Grok.
///
/// Layout, chips, path field, enable/save/delete/reorder, and optional
/// refresh/reconnect actions are identical; call sites only supply provider
/// accent, path copy, status presentation, and capability flags.
struct ProviderAccountProfileRow: View {
    // MARK: Lifecycle

    init(
        accountName: String,
        isDefault: Bool,
        isEnabled: Bool,
        accent: Color,
        pathLabel: String,
        pathPlaceholder: String,
        resolvedPath: String,
        defaultPathHelp: String?,
        statusPresentation: SettingsStatusPresentation,
        canDisable: Bool = true,
        canRemove: Bool = true,
        canMoveUp: Bool = false,
        canMoveDown: Bool = false,
        isRefreshing: Bool = false,
        showsRefresh: Bool = false,
        showsReconnect: Bool = false,
        reconnectProviderName: String = "",
        deleteMessage: String,
        onEnabledChange: @escaping (Bool) -> Void,
        onSave: @escaping (String, String?) -> Void,
        onRemove: @escaping () -> Void,
        onRefresh: (() -> Void)? = nil,
        onReconnect: (() -> Void)? = nil,
        onMoveUp: (() -> Void)? = nil,
        onMoveDown: (() -> Void)? = nil
    ) {
        self.accountName = accountName
        self.isDefault = isDefault
        self.isEnabled = isEnabled
        self.accent = accent
        self.pathLabel = pathLabel
        self.pathPlaceholder = pathPlaceholder
        self.resolvedPath = resolvedPath
        self.defaultPathHelp = defaultPathHelp
        self.statusPresentation = statusPresentation
        self.canDisable = canDisable
        self.canRemove = canRemove
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.isRefreshing = isRefreshing
        self.showsRefresh = showsRefresh
        self.showsReconnect = showsReconnect
        self.reconnectProviderName = reconnectProviderName
        self.deleteMessage = deleteMessage
        self.onEnabledChange = onEnabledChange
        self.onSave = onSave
        self.onRemove = onRemove
        self.onRefresh = onRefresh
        self.onReconnect = onReconnect
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
        _draft = State(initialValue: ProviderAccountProfileDraft(
            name: accountName,
            resolvedPath: resolvedPath
        ))
        _identity = State(initialValue: AccountIdentity(
            name: accountName,
            resolvedPath: resolvedPath,
            isEnabled: isEnabled
        ))
    }

    // MARK: Internal

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isDefault ? "person.crop.circle" : "person.crop.circle.badge.plus")
                .foregroundStyle(accent)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    fieldLabel("Account name")

                    TextField("Account label", text: $draft.name)
                        .settingsInput(width: AccountProfileRowMetrics.fieldWidth)
                        .accessibilityLabel("Account name for \(accountName)")
                        .onSubmit(saveChanges)

                    MeterBarChip(
                        isDefault ? "Default" : "Profile",
                        tint: isDefault ? MeterBarTheme.appAccent : accent,
                        style: .glass
                    )

                    StatusPill(presentation: statusPresentation)
                        .font(.caption)
                        .accessibilityLabel("Status for \(accountName)")
                }

                HStack(spacing: 8) {
                    fieldLabel(pathLabel)

                    TextField(pathPlaceholder, text: $draft.path)
                        .settingsInput(width: AccountProfileRowMetrics.fieldWidth)
                        .accessibilityLabel("\(pathLabel) for \(accountName)")
                        .onSubmit(saveChanges)

                    Button {
                        chooseDirectory()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Choose \(pathLabel) for \(accountName)")
                    .help("Choose \(pathLabel)")
                }

                if let defaultPathHelp, isDefault {
                    Text(defaultPathHelp)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, AccountProfileRowMetrics.labelWidth + 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Toggle("Enabled", isOn: Binding(
                    get: { isEnabled },
                    set: onEnabledChange
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isEnabled && !canDisable)
                .accessibilityLabel("Track \(accountName)")
                .help(enablementHelp)

                if showsRefresh {
                    authActionButton(.refresh)
                        .frame(width: AccountProfileRowMetrics.actionWidth)
                        .disabled(!isEnabled || isRefreshing)
                }

                if showsReconnect {
                    authActionButton(.reconnect)
                        .disabled(isRefreshing)
                }

                if onMoveUp != nil || onMoveDown != nil {
                    Button { onMoveUp?() } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canMoveUp)
                        .help("Move account up")
                    Button { onMoveDown?() } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canMoveDown)
                        .help("Move account down")
                }

                Button(action: saveChanges) {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(width: AccountProfileRowMetrics.actionWidth)
                .disabled(savePayload == nil)
                .accessibilityLabel("Save changes for \(accountName)")
                .help("Save account changes")

                if !isDefault {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(width: AccountProfileRowMetrics.actionWidth)
                    .disabled(!canRemove)
                    .accessibilityLabel("Delete \(accountName)")
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
        .onChange(of: accountName) { _, _ in reconcileDraftFromProps() }
        .onChange(of: resolvedPath) { _, _ in reconcileDraftFromProps() }
        .onChange(of: isEnabled) { _, _ in reconcileDraftFromProps() }
        .confirmationDialog(
            ProviderAccountReconnectConfirmation.title(accountName: accountName),
            isPresented: $showingReconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                ProviderAccountReconnectConfirmation.confirmButtonTitle,
                role: .destructive
            ) {
                onReconnect?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                ProviderAccountReconnectConfirmation.message(
                    accountName: accountName,
                    providerDisplayName: reconnectProviderName
                )
            )
        }
        .confirmationDialog(
            "Delete \(accountName)?",
            isPresented: $showingDeleteConfirmation
        ) {
            Button("Delete Account", role: .destructive, action: onRemove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    // MARK: Private

    private struct AccountIdentity: Equatable {
        let name: String
        let resolvedPath: String
        let isEnabled: Bool
    }

    private let accountName: String
    private let isDefault: Bool
    private let isEnabled: Bool
    private let accent: Color
    private let pathLabel: String
    private let pathPlaceholder: String
    private let resolvedPath: String
    private let defaultPathHelp: String?
    private let statusPresentation: SettingsStatusPresentation
    private let canDisable: Bool
    private let canRemove: Bool
    private let canMoveUp: Bool
    private let canMoveDown: Bool
    private let isRefreshing: Bool
    private let showsRefresh: Bool
    private let showsReconnect: Bool
    private let reconnectProviderName: String
    private let deleteMessage: String
    private let onEnabledChange: (Bool) -> Void
    private let onSave: (String, String?) -> Void
    private let onRemove: () -> Void
    private let onRefresh: (() -> Void)?
    private let onReconnect: (() -> Void)?
    private let onMoveUp: (() -> Void)?
    private let onMoveDown: (() -> Void)?

    @State private var draft: ProviderAccountProfileDraft
    @State private var identity: AccountIdentity
    @State private var showingReconnectConfirmation = false
    @State private var showingDeleteConfirmation = false

    private var savePayload: ProviderAccountProfileSave? {
        draft.savePayload(
            currentName: accountName,
            resolvedPath: resolvedPath,
            isDefault: isDefault
        )
    }

    private var enablementHelp: String {
        if isEnabled, !canDisable {
            return "Enable another account before disabling this one"
        }
        return isEnabled ? "Disable account" : "Enable account"
    }

    private var deleteHelp: String {
        canRemove ? "Delete account" : "Enable another account before deleting this one"
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .frame(width: AccountProfileRowMetrics.labelWidth, alignment: .leading)
    }

    private func reconcileDraftFromProps() {
        let next = AccountIdentity(
            name: accountName,
            resolvedPath: resolvedPath,
            isEnabled: isEnabled
        )
        draft.reconcile(
            previousName: identity.name,
            previousResolvedPath: identity.resolvedPath,
            updatedName: next.name,
            updatedResolvedPath: next.resolvedPath
        )
        identity = next
    }

    private func saveChanges() {
        guard let savePayload else { return }
        onSave(savePayload.name, savePayload.path)
        // Parent store republication drives `reconcileDraftFromProps`. Commit
        // only the name immediately so a second save click is a no-op before
        // the store publishes; path resolution (especially clear-to-default)
        // must come from the parent.
        draft.name = savePayload.name
        identity = AccountIdentity(
            name: savePayload.name,
            resolvedPath: identity.resolvedPath,
            isEnabled: isEnabled
        )
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use"
        if panel.runModal() == .OK, let url = panel.url {
            draft.path = url.path
        }
    }

    private func authActionButton(_ action: ProviderAccountAuthAction) -> some View {
        Button {
            switch action.route {
            case .performRefresh:
                onRefresh?()
            case .requestReconnectConfirmation:
                showingReconnectConfirmation = true
            }
        } label: {
            if isRefreshing, action == .refresh {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(action.accessibilityLabel(accountName: accountName))
            } else if action.showsVisibleTitle {
                Label(action.title, systemImage: action.systemImage)
            } else {
                Label(action.title, systemImage: action.systemImage)
                    .labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(action.accessibilityLabel(accountName: accountName))
        .accessibilityHint(action.help(accountName: accountName))
        .help(action.help(accountName: accountName))
    }
}
