import SwiftUI

/// Opt-in private iCloud aggregation, device identity, and stale-installation
/// cleanup. This page never triggers CloudKit while the master toggle is off.
struct ICloudUsageSettingsView: View {
    @StateObject private var settings = ICloudUsageSettingsStore.shared
    @StateObject private var aggregation = ICloudUsageAggregationService.shared
    @StateObject private var costTracker = CostTracker.shared

    @State private var deviceNameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsPanelSection(
                title: "Multi-Mac Usage",
                systemImage: "icloud",
                color: MeterBarTheme.appAccent
            ) {
                SettingsNotice(
                    text: "Opt in to combine daily token and estimated-cost totals across your Macs. "
                        + "MeterBar stores compact rollups in your private iCloud database—never raw logs "
                        + "or credentials.",
                    color: .secondary
                )

                SettingsRowView(
                    title: "Sync usage with iCloud",
                    detail: "Off by default. Off makes no CloudKit requests."
                ) {
                    Toggle("", isOn: Binding(
                        get: { settings.isEnabled },
                        set: { enabled in
                            settings.setEnabled(enabled)
                            Task {
                                await aggregation.sync(
                                    localSummary: costTracker.costSummary,
                                    quotaSnapshots: []
                                )
                            }
                        }
                    ))
                    .labelsHidden()
                    .meterBarSwitch()
                }

                if settings.isEnabled {
                    SettingsDivider()
                    SettingsRowView(
                        title: "This Mac",
                        detail: "A stable installation ID keeps reinstalls and stale devices distinguishable."
                    ) {
                        TextField("Mac name", text: $deviceNameDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onSubmit { saveDeviceName() }
                    }

                    SettingsRowView(title: "Sync now", detail: syncDetail) {
                        Button {
                            saveDeviceName()
                            Task {
                                await aggregation.sync(
                                    localSummary: costTracker.costSummary,
                                    quotaSnapshots: []
                                )
                            }
                        } label: {
                            if aggregation.isSyncing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                                    .labelStyle(.iconOnly)
                            }
                        }
                        .buttonStyle(.glass)
                        .disabled(aggregation.isSyncing)
                    }

                    if let error = aggregation.lastError {
                        SettingsNotice(text: error, color: MeterBarTheme.warning)
                    }
                }
            }

            if settings.isEnabled {
                deviceSection
            }
        }
        .onAppear { deviceNameDraft = settings.deviceName }
    }

    private var syncDetail: String {
        guard let lastSyncedAt = aggregation.lastSyncedAt else { return "Not synced yet" }
        return "Last synced \(UsageFormat.relative(lastSyncedAt))"
    }

    private var deviceSection: some View {
        SettingsPanelSection(title: "Devices", systemImage: "desktopcomputer", color: MeterBarTheme.appAccent) {
            let devices = aggregation.aggregate?.devices ?? [
                ICloudUsageDevice(id: settings.deviceID, name: settings.deviceName, lastSeenAt: Date())
            ]
            ForEach(devices) { device in
                SettingsRowView(
                    title: device.name,
                    detail: device.id == settings.deviceID
                        ? "This Mac · \(UsageFormat.relative(device.lastSeenAt))"
                        : "Last seen \(UsageFormat.relative(device.lastSeenAt))"
                ) {
                    if device.id != settings.deviceID {
                        Button("Remove", role: .destructive) {
                            Task { await aggregation.removeDevice(device) }
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Text("Current")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func saveDeviceName() {
        settings.setDeviceName(deviceNameDraft)
        deviceNameDraft = settings.deviceName
    }
}
