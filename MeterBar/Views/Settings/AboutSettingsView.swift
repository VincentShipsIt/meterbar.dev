import MeterBarShared
import SwiftUI

/// The "About" settings tab: version, software-update check, and project links.
/// Extracted from the SettingsView monolith.
struct AboutSettingsView: View {
    struct LinkDestination: Identifiable {
        let id: String
        let title: String
        let detail: String
        let url: URL
    }

    // MARK: Internal

    static let links = [
        LinkDestination(
            id: "website",
            title: "Website",
            detail: "meterbar.dev",
            url: destination("https://meterbar.dev")
        ),
        LinkDestination(
            id: "github",
            title: "GitHub Repository",
            detail: "VincentShipsIt/meterbar.dev",
            url: destination("https://github.com/VincentShipsIt/meterbar.dev")
        ),
        LinkDestination(
            id: "x",
            title: "X",
            detail: "@shipshitdev",
            url: destination("https://x.com/shipshitdev")
        ),
    ]

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

            SettingsDivider()

            ForEach(Self.links) { link in
                SettingsRowView(title: link.title, detail: link.detail) {
                    Link("Open", destination: link.url)
                    .buttonStyle(.bordered)
                }
            }
        }
        .onAppear { softwareUpdates.refreshState() }
    }

    // MARK: Private

    @StateObject private var softwareUpdates = SoftwareUpdateController.shared

    private static func destination(_ value: String) -> URL {
        guard let url = URL(string: value) else {
            preconditionFailure("Invalid static About URL: \(value)")
        }
        return url
    }

    private static var appVersionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return short == build ? short : "\(short) (\(build))"
    }
}
