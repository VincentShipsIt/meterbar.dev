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
    static let shared = ClaudeCredentialFingerprintStore(
        readKeychainResult: {
            ClaudeCredentialFingerprintStore.keychainFingerprint(service: $0)
        },
        readFile: { ClaudeCredentialFingerprintStore.fileFingerprint(path: $0) },
        denialStore: ClaudeKeychainDenialStore(),
        isOAuthEnabled: { ClaudeCodeLocalService.isOAuthUsageEnabled() }
    )

    private let readKeychainResult:
        @Sendable (String) -> ClaudeKeychainReadOutcome<ClaudeCredentialFingerprint>
    private let readFile: @Sendable (String) -> ClaudeCredentialFingerprint?
    private let denialStore: ClaudeKeychainDenialStore
    private let isOAuthEnabled: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    /// Compatibility initializer for pure candidate-order tests.
    init(
        readKeychain: @escaping @Sendable (String) -> ClaudeCredentialFingerprint?,
        readFile: @escaping @Sendable (String) -> ClaudeCredentialFingerprint?
    ) {
        self.readKeychainResult = {
            readKeychain($0).map(ClaudeKeychainReadOutcome.value) ?? .notFound
        }
        self.readFile = readFile
        self.denialStore = ClaudeKeychainDenialStore()
        self.isOAuthEnabled = { true }
        self.now = { Date() }
    }

    init(
        readKeychainResult: @escaping @Sendable (
            String
        ) -> ClaudeKeychainReadOutcome<ClaudeCredentialFingerprint>,
        readFile: @escaping @Sendable (String) -> ClaudeCredentialFingerprint?,
        denialStore: ClaudeKeychainDenialStore,
        isOAuthEnabled: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.readKeychainResult = readKeychainResult
        self.readFile = readFile
        self.denialStore = denialStore
        self.isOAuthEnabled = isOAuthEnabled
        self.now = now
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
                guard isOAuthEnabled() else { continue }
                let decision = ClaudeKeychainPromptPolicy.decision(
                    requestedMode: .background,
                    deniedAt: denialStore.deniedAt(for: service),
                    now: now()
                )
                guard case .query = decision else { continue }

                switch readKeychainResult(service) {
                case let .value(fingerprint):
                    denialStore.clearDenial(for: service)
                    return fingerprint
                case .notFound:
                    denialStore.clearDenial(for: service)
                case .interactionRequired, .denied:
                    denialStore.recordDenial(for: service, at: now())
                case .failure:
                    break
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
    static func keychainFingerprint(
        service: String,
        backend: KeychainBackend = SecItemKeychainBackend()
    ) -> ClaudeKeychainReadOutcome<ClaudeCredentialFingerprint> {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let query = ClaudeKeychainQuery.applyingAccessMode(.background, to: baseQuery)

        var result: AnyObject?
        let status = backend.copyMatching(query: query, result: &result)
        let fingerprint: ClaudeCredentialFingerprint?
        if let attributes = result as? [String: Any],
           let modificationDate = attributes[kSecAttrModificationDate as String] as? Date {
            fingerprint = .keychain(service: service, modificationDate: modificationDate)
        } else {
            fingerprint = nil
        }
        return ClaudeKeychainQuery.outcome(
            status: status,
            result: fingerprint,
            mode: .background
        )
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
