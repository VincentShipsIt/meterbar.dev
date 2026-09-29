import Foundation
import MeterBarShared

/// Small string settings that the bundled CLI must see exactly as the app does.
///
/// The CLI is a separate process with its own `UserDefaults` domain, so a value
/// the user picks in Settings (Z.ai's region, later Copilot's account scope) is
/// mirrored into the app-group directory alongside the other refresh
/// configuration. It never holds a credential — those live in the Keychain.
nonisolated enum ProviderSharedSettings {
    private static let fileName = "refresh-provider-settings-v1.json"

    static func value(
        for key: String,
        directory: URL? = SharedMetricsStore.containerURL
    ) -> String? {
        load(directory: directory)[key]
    }

    static func set(
        _ value: String?,
        for key: String,
        directory: URL? = SharedMetricsStore.containerURL
    ) {
        guard let directory else { return }
        var settings = load(directory: directory)
        settings[key] = value
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? SecureFileWriter.write(data, to: directory.appendingPathComponent(fileName))
    }

    private static func load(directory: URL?) -> [String: String] {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}

/// The user's Z.ai region choice. Unknown or missing values fall back to the
/// international host, never to anything user-supplied.
nonisolated enum ZaiRegionSetting {
    static let key = "zaiCodingPlanRegion"

    static func current(directory: URL? = SharedMetricsStore.containerURL) -> ZaiCodingPlanRegion {
        ProviderSharedSettings.value(for: key, directory: directory)
            .flatMap(ZaiCodingPlanRegion.init(rawValue:)) ?? .default
    }

    static func save(_ region: ZaiCodingPlanRegion, directory: URL? = SharedMetricsStore.containerURL) {
        ProviderSharedSettings.set(region.rawValue, for: key, directory: directory)
    }
}
