import Foundation
import Security

/// Privacy-safe identity for the credential backing one Claude Code profile.
///
/// Keychain fingerprints contain metadata only; they never read, hash, log, or
/// persist the OAuth payload. The file fallback follows the same rule by using
/// filesystem metadata instead of credential bytes.
nonisolated enum ClaudeCredentialFingerprint: Equatable, Sendable {
    case keychain(service: String, modificationDate: Date)
    case file(path: String, modificationDate: Date, size: UInt64)
}

/// Reads the first metadata fingerprint in the same candidate order as
/// `ClaudeCredentialStore`.
nonisolated struct ClaudeCredentialFingerprintStore: Sendable {
    static let shared = ClaudeCredentialFingerprintStore()

    private let readKeychain: @Sendable (String) -> ClaudeCredentialFingerprint?
    private let readFile: @Sendable (String) -> ClaudeCredentialFingerprint?

    init(
        readKeychain: @escaping @Sendable (String) -> ClaudeCredentialFingerprint? = {
            ClaudeCredentialFingerprintStore.keychainFingerprint(service: $0)
        },
        readFile: @escaping @Sendable (String) -> ClaudeCredentialFingerprint? = {
            ClaudeCredentialFingerprintStore.fileFingerprint(path: $0)
        }
    ) {
        self.readKeychain = readKeychain
        self.readFile = readFile
    }

    func fingerprint(
        for account: ClaudeCodeAccount,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> ClaudeCredentialFingerprint? {
        let candidates = ClaudeCredentialResolver.candidates(
            for: account,
            environment: environment,
            realHomeDirectory: realHomeDirectory
        )

        for source in candidates {
            switch source {
            case let .keychain(service):
                if let fingerprint = readKeychain(service) {
                    return fingerprint
                }
            case let .file(path):
                if let fingerprint = readFile(path) {
                    return fingerprint
                }
            }
        }
        return nil
    }

    /// Reads Keychain attributes without requesting the secret payload.
    static func keychainFingerprint(service: String) -> ClaudeCredentialFingerprint? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let attributes = result as? [String: Any],
              let modificationDate = attributes[kSecAttrModificationDate as String] as? Date else {
            return nil
        }
        return .keychain(service: service, modificationDate: modificationDate)
    }

    static func fileFingerprint(path: String) -> ClaudeCredentialFingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modificationDate = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return .file(
            path: path,
            modificationDate: modificationDate,
            size: size.uint64Value
        )
    }
}
