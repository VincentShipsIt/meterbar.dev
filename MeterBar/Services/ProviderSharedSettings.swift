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

/// Where GitHub Copilot's billing is read from: the billing scope, the account
/// login, and (for organization-managed licences) the organization. Logins are
/// validated on the way in and on the way out, because they are interpolated
/// into a request path.
nonisolated struct GitHubCopilotAccountConfig: Equatable {
    var scope: GitHubCopilotBillingScope = .personal
    var username: String?
    var organization: String?

    /// Enough to build a request: a username, and an organization when the
    /// licence is organization-managed.
    var isComplete: Bool {
        username != nil && (scope == .personal || organization != nil)
    }

    private static let scopeKey = "githubCopilotScope"
    private static let usernameKey = "githubCopilotUsername"
    private static let organizationKey = "githubCopilotOrganization"
    private static let supportKey = "githubCopilotSupport"

    static func load(directory: URL? = SharedMetricsStore.containerURL) -> GitHubCopilotAccountConfig {
        func login(_ key: String) -> String? {
            ProviderSharedSettings.value(for: key, directory: directory).flatMap {
                GitHubLogin.isValid($0) ? $0 : nil
            }
        }
        return GitHubCopilotAccountConfig(
            scope: ProviderSharedSettings.value(for: scopeKey, directory: directory)
                .flatMap(GitHubCopilotBillingScope.init(rawValue:)) ?? .personal,
            username: login(usernameKey),
            organization: login(organizationKey)
        )
    }

    /// Invalid logins are dropped rather than stored, so a bad paste can never
    /// be read back as a request path.
    func save(directory: URL? = SharedMetricsStore.containerURL) {
        ProviderSharedSettings.set(scope.rawValue, for: Self.scopeKey, directory: directory)
        let validUsername = username.flatMap { GitHubLogin.isValid($0) ? $0 : nil }
        let validOrganization = organization.flatMap { GitHubLogin.isValid($0) ? $0 : nil }
        ProviderSharedSettings.set(validUsername, for: Self.usernameKey, directory: directory)
        ProviderSharedSettings.set(validOrganization, for: Self.organizationKey, directory: directory)
    }

    /// The last account classification, persisted (as a secret-free token) so
    /// the CLI's `doctor` can report it without making a request.
    static func loadSupport(directory: URL? = SharedMetricsStore.containerURL) -> GitHubCopilotAccountSupport? {
        ProviderSharedSettings.value(for: supportKey, directory: directory)
            .flatMap(GitHubCopilotAccountSupport.init(token:))
    }

    static func saveSupport(_ support: GitHubCopilotAccountSupport?, directory: URL? = SharedMetricsStore.containerURL) {
        ProviderSharedSettings.set(support?.token, for: supportKey, directory: directory)
    }
}
