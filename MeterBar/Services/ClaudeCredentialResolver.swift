import CryptoKit
import Foundation
import MeterBarShared

/// Where a Claude Code profile's OAuth credential can live, in the order it is
/// worth looking. The Keychain is authoritative on macOS; the file is what
/// Claude Code writes when the Keychain is unavailable to it.
nonisolated enum ClaudeCredentialSource: Equatable, Sendable {
    case keychain(service: String)
    case file(path: String)
}

/// Maps a `ClaudeCodeAccount` onto the credential Claude Code itself wrote for
/// that profile.
///
/// Claude Code scopes its Keychain item per config directory:
/// `Claude Code-credentials-<first 8 hex of sha256(configDirPath)>`. MeterBar
/// previously read only the unscoped `Claude Code-credentials` item, so every
/// profile with a `CLAUDE_CONFIG_DIR` was forced onto the CLI parser — and the
/// CLI no longer renders `/usage` headlessly once a profile is logged out.
///
/// Pure derivation only: no I/O, so the ordering policy is fully testable.
/// `ClaudeCredentialStore` is the thin shell that reads the candidates.
nonisolated enum ClaudeCredentialResolver {
    /// The unscoped item, written for the canonical `~/.claude` profile.
    static let bareKeychainService = "Claude Code-credentials"

    private static let credentialsFileName = ".credentials.json"
    private static let serviceSuffixLength = 8

    /// `Claude Code-credentials-<suffix>` for a resolved config-directory path.
    /// The suffix is the first 8 lowercase hex characters of the SHA-256 of the
    /// path's UTF-8 bytes — reproduce with
    /// `printf '%s' <path> | shasum -a 256 | cut -c1-8`.
    static func keychainService(forConfigDirectory configDirectory: String) -> String {
        let digest = SHA256.hash(data: Data(configDirectory.utf8))
        let suffix = digest.map { String(format: "%02x", $0) }.joined().prefix(serviceSuffixLength)
        return "\(bareKeychainService)-\(suffix)"
    }

    /// The config directory this account actually reads: its own override when
    /// set, otherwise whatever the environment selects for the default profile.
    static func configDirectory(
        for account: ClaudeCodeAccount,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> String {
        if let override = account.configDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return ClaudeCodeAccount.expandConfigDirectory(override, realHomeDirectory: realHomeDirectory)
        }
        return ClaudeCodeAccount.defaultConfigDirectory(
            environment: environment,
            realHomeDirectory: realHomeDirectory
        )
    }

    /// Credential sources to try, most specific first.
    ///
    /// The bare item is offered *only* to the canonical `~/.claude` profile. It
    /// belongs to whichever identity last logged in unscoped, so letting a
    /// scoped profile reach it would report another account's usage — the
    /// cross-identity contamination that OAuth was previously disabled outright
    /// to avoid. Excluding it here makes that impossible by construction, which
    /// is what lets every profile attempt OAuth again.
    static func candidates(
        for account: ClaudeCodeAccount,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> [ClaudeCredentialSource] {
        let directory = configDirectory(
            for: account,
            environment: environment,
            realHomeDirectory: realHomeDirectory
        )

        var sources: [ClaudeCredentialSource] = [
            .keychain(service: keychainService(forConfigDirectory: directory))
        ]
        if directory == canonicalConfigDirectory(realHomeDirectory: realHomeDirectory) {
            sources.append(.keychain(service: bareKeychainService))
        }
        sources.append(.file(path: (directory as NSString).appendingPathComponent(credentialsFileName)))
        return sources
    }

    /// The unscoped profile Claude Code uses with no `CLAUDE_CONFIG_DIR` set.
    static func canonicalConfigDirectory(
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> String {
        (realHomeDirectory as NSString).appendingPathComponent(".claude")
    }
}

/// Reads the first credential blob that resolves for an account.
///
/// `nonisolated`: a Keychain read can raise a blocking approval dialog and a
/// file read hits disk — neither belongs on the main actor.
nonisolated struct ClaudeCredentialStore: Sendable {
    static let shared = ClaudeCredentialStore()

    private let readKeychain: @Sendable (String) -> Data?
    private let readFile: @Sendable (String) -> Data?

    init(
        readKeychain: @escaping @Sendable (String) -> Data? = ClaudeCredentialStore.keychainPayload,
        readFile: @escaping @Sendable (String) -> Data? = ClaudeCredentialStore.filePayload
    ) {
        self.readKeychain = readKeychain
        self.readFile = readFile
    }

    /// The raw credentials JSON for `account`, or nil when no candidate holds
    /// one. An empty payload is treated as a miss: a stale, emptied Keychain
    /// item must not shadow a working file fallback.
    func credentialsData(
        for account: ClaudeCodeAccount,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> Data? {
        let candidates = ClaudeCredentialResolver.candidates(
            for: account,
            environment: environment,
            realHomeDirectory: realHomeDirectory
        )

        for source in candidates {
            let payload: Data?
            switch source {
            case let .keychain(service):
                payload = readKeychain(service)
            case let .file(path):
                payload = readFile(path)
            }
            if let payload, !payload.isEmpty {
                return payload
            }
        }
        return nil
    }

    static func keychainPayload(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }

    static func filePayload(path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }
}
