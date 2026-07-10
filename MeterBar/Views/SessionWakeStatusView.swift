import SwiftUI

// MARK: - SessionWakeTone color mapping

extension SessionWakeTone {
    /// Resolves the semantic tone to an adaptive theme color. Kept out of the
    /// model so `SessionWakeStatus` stays SwiftUI-free and unit-testable.
    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .active: return MeterBarTheme.appAccent
        case .waiting: return MeterBarTheme.appAccent
        case .warning: return MeterBarTheme.warning
        case .danger: return MeterBarTheme.danger
        case .success: return MeterBarTheme.success
        }
    }
}

// MARK: - SessionWakeStatusBadge

/// Compact icon + label pill for a wake status. Shared by the Settings pane and
/// the menu-bar popover so both render the same vocabulary.
struct SessionWakeStatusBadge: View {
    let status: SessionWakeStatus

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(status.label)
                .font(.caption)
                .fontWeight(.semibold)
        }
        .foregroundStyle(status.tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(status.tone.color.opacity(0.14))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session Wake status: \(status.label)")
    }
}

// MARK: - SessionWakeStatusView

/// The read-only status surface: badge, detail, selected account, reset
/// countdown, Preview eligibility, and last-run counts. Rendered identically in
/// the Settings Automation pane and the menu-bar popover from one shared state
/// binding (issue #98). No control logic lives here — see
/// ``SessionWakeWatcherControl``.
struct SessionWakeStatusView: View {
    @ObservedObject var coordinator: SessionWakeCoordinator
    @ObservedObject var settings: SessionWakeSettingsStore
    @ObservedObject var accountStore: ClaudeCodeAccountStore

    init(
        coordinator: SessionWakeCoordinator = .shared,
        settings: SessionWakeSettingsStore = .shared,
        accountStore: ClaudeCodeAccountStore = .shared
    ) {
        self.coordinator = coordinator
        self.settings = settings
        self.accountStore = accountStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                SessionWakeStatusBadge(status: coordinator.status)
                Spacer(minLength: 6)
                accountLabel
            }

            if let detail = coordinator.status.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            resetCountdown

            eligibilitySummary

            lastRunSummary
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Private

    private var selectedAccountName: String? {
        guard let id = settings.wakeAccountID else { return nil }
        return accountStore.accounts.first { $0.id == id }?.name
    }

    @ViewBuilder private var accountLabel: some View {
        if let name = selectedAccountName {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 10))
                Text(name)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        } else {
            Text("No account selected")
                .font(.caption2)
                .foregroundStyle(MeterBarTheme.warning)
        }
    }

    @ViewBuilder private var resetCountdown: some View {
        if case let .waiting(until, _) = coordinator.status, let until {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                Text("Resets \(until, style: .relative)")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var eligibilitySummary: some View {
        if let eligibility = coordinator.eligibility {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(eligibility.eligibleCount) eligible · \(eligibility.skippedCount) skipped")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                ForEach(eligibility.skips, id: \.reason) { skip in
                    Text("· \(skip.reason): \(skip.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let note = eligibility.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var lastRunSummary: some View {
        if let lastRun = coordinator.lastRun {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 10))
                Text("Last run: \(lastRun.countsLine)")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - SessionWakeWatcherControl

/// The shared watcher control: the Wake Watcher kill-switch plus Preview and
/// Resume Now actions. Used in both Settings and the popover so both operate the
/// exact same persisted intent and coordinator (issue #98: "one shared state
/// binding"). Arming is disabled unless every precondition holds; Preview stays
/// available even while the feature is off (read-only dry run).
struct SessionWakeWatcherControl: View {
    @ObservedObject var coordinator: SessionWakeCoordinator
    @ObservedObject var settings: SessionWakeSettingsStore

    /// Compact layout drops button labels' verbosity for the narrow popover.
    var isCompact = false

    init(
        coordinator: SessionWakeCoordinator = .shared,
        settings: SessionWakeSettingsStore = .shared,
        isCompact: Bool = false
    ) {
        self.coordinator = coordinator
        self.settings = settings
        self.isCompact = isCompact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: watcherBinding) {
                if !isCompact {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wake Watcher")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("Poll quota and resume when the window reopens.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Wake Watcher")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
            }
            .toggleStyle(.switch)
            .disabled(!settings.canArmWatcher && !settings.isWatcherArmed)

            HStack(spacing: 8) {
                Button {
                    Task { await coordinator.preview() }
                } label: {
                    Label("Preview", systemImage: "eye")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .help("Read-only dry run of which sessions would resume. Makes no changes.")

                Button {
                    Task { await coordinator.resumeNow() }
                } label: {
                    Label("Resume Now", systemImage: "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(!settings.isFeatureEnabled)
                .help("Resume once, only if quota is currently available.")
            }
        }
    }

    private var watcherBinding: Binding<Bool> {
        Binding(
            get: { settings.isWatcherArmed },
            set: { settings.setWatcherArmed($0) }
        )
    }
}

// MARK: - SessionWakePopoverCard

/// The Session Wake card for the menu-bar popover. Renders only when the Claude
/// Code provider is visible and the feature is enabled, giving the user the same
/// status and the same Wake Watcher kill-switch as Settings without opening it
/// (issue #98 / PRD FR-4). Reads the same shared singletons, so both surfaces
/// stay in sync.
struct SessionWakePopoverCard: View {
    @ObservedObject var coordinator: SessionWakeCoordinator
    @ObservedObject var settings: SessionWakeSettingsStore
    @ObservedObject var providerVisibility: ProviderVisibilityStore

    init(
        coordinator: SessionWakeCoordinator = .shared,
        settings: SessionWakeSettingsStore = .shared,
        providerVisibility: ProviderVisibilityStore = .shared
    ) {
        self.coordinator = coordinator
        self.settings = settings
        self.providerVisibility = providerVisibility
    }

    var body: some View {
        if providerVisibility.isEnabled(.claudeCode), settings.isFeatureEnabled {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "powersleep")
                        .font(.caption)
                        .foregroundStyle(MeterBarTheme.appAccent)
                    Text("Session Wake")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Spacer(minLength: 6)
                }

                SessionWakeStatusView(coordinator: coordinator, settings: settings)

                SessionWakeWatcherControl(
                    coordinator: coordinator,
                    settings: settings,
                    isCompact: true
                )
            }
            .padding(10)
            .meterBarCardSurface(cornerRadius: 10)
        }
    }
}
