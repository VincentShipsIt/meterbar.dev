import MeterBarShared
import SwiftUI

/// The "About" settings tab: version, software-update check, and website link.
/// Extracted from the SettingsView monolith.
struct AboutSettingsView: View {
    // MARK: Internal

    var body: some View {
        SettingsPanelSection(title: "About MeterBar", systemImage: "info.circle", color: MeterBarTheme.appAccent) {
            SettingsRowView(
                title: "Version",
                detail: "Track your AI coding assistant usage limits from the macOS menu bar."
            ) {
                Text(Self.appVersionString)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            SettingsDivider()

            SettingsRowView(
                title: "Software Update",
                detail: softwareUpdates.configurationError ?? "Check for a new signed MeterBar release now."
            ) {
                Button("Check Now") {
                    softwareUpdates.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .disabled(!softwareUpdates.canCheckForUpdates)
            }

            SettingsRowView(
                title: "Website",
                detail: "meterbar.dev"
            ) {
                Link("Open", destination: URL(string: "https://meterbar.dev")!)
                    .buttonStyle(.bordered)
            }
        }
        .onAppear { softwareUpdates.refreshState() }
    }

    // MARK: Private

    @StateObject private var softwareUpdates = SoftwareUpdateController.shared

    private static var appVersionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return short == build ? short : "\(short) (\(build))"
    }
}
