import CryptoKit
import Foundation
import Security
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
    private enum KeychainCandidateResult {
        case value(Data)
        case continueWalk(
            outcome: ClaudeKeychainReadOutcome<Data>,
            consumedInteractivePrompt: Bool
        )
    }

    static let shared = ClaudeCredentialStore(
        readKeychainResult: { service, mode in
            ClaudeCredentialStore.keychainPayload(service: service, mode: mode)
        },
        readFile: { ClaudeCredentialStore.filePayload(path: $0) },
        denialStore: ClaudeKeychainDenialStore(),
        isOAuthEnabled: { ClaudeCodeLocalService.isOAuthUsageEnabled() }
    )

    private let readKeychainResult:
        @Sendable (String, ClaudeKeychainAccessMode) -> ClaudeKeychainReadOutcome<Data>
    private let readFile: @Sendable (String) -> Data?
    private let denialStore: ClaudeKeychainDenialStore
    private let isOAuthEnabled: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    /// Compatibility initializer for pure candidate-order tests.
    init(
        readKeychain: @escaping @Sendable (String) -> Data?,
        readFile: @escaping @Sendable (String) -> Data?
    ) {
        self.readKeychainResult = { service, _ in
            readKeychain(service).map(ClaudeKeychainReadOutcome.value) ?? .notFound
        }
        self.readFile = readFile
        self.denialStore = ClaudeKeychainDenialStore()
        self.isOAuthEnabled = { true }
        self.now = { Date() }
    }

    init(
        readKeychainResult: @escaping @Sendable (
            String,
            ClaudeKeychainAccessMode
        ) -> ClaudeKeychainReadOutcome<Data>,
        readFile: @escaping @Sendable (String) -> Data?,
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

    /// The raw credentials JSON for `account`, or nil when no candidate holds
    /// one. An empty payload is treated as a miss: a stale, emptied Keychain
    /// item must not shadow a working file fallback.
    func credentialsData(
        for account: ClaudeCodeAccount,
        mode: ClaudeKeychainAccessMode = .background,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> Data? {
        guard case let .value(data) = credentialsDataResult(
            for: account,
            mode: mode,
            environment: environment,
            realHomeDirectory: realHomeDirectory
        ) else {
            return nil
        }
        return data
    }

    /// Resolves the credential without erasing the difference between an
    /// absent item and one that exists behind an unavailable authorization
    /// interaction. Callers use that distinction to avoid false logout state.
    func credentialsDataResult(
        for account: ClaudeCodeAccount,
        mode: ClaudeKeychainAccessMode = .background,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> ClaudeKeychainReadOutcome<Data> {
        let candidates = ClaudeCredentialResolver.candidates(
            for: account,
            environment: environment,
            realHomeDirectory: realHomeDirectory
        )

        var remainingKeychainMode = mode
        var promptBudgetConsumed = false
        var deferredOutcome: ClaudeKeychainReadOutcome<Data> = .notFound

        for source in candidates {
            switch source {
            case let .keychain(service):
                guard isOAuthEnabled() else { continue }
                switch resolveKeychainCandidate(
                    service: service,
                    mode: remainingKeychainMode
                ) {
                case let .value(payload):
                    return .value(payload)
                case let .continueWalk(outcome, consumedInteractivePrompt):
                    deferredOutcome = Self.mergedOutcome(
                        existing: deferredOutcome,
                        candidate: outcome
                    )
                    promptBudgetConsumed = promptBudgetConsumed || consumedInteractivePrompt
                    if mode == .interactive, promptBudgetConsumed {
                        remainingKeychainMode = .background
                    }
                }
            case let .file(path):
                if let payload = readFile(path), !payload.isEmpty {
                    return .value(payload)
                }
            }
        }
        return deferredOutcome
    }

    private func resolveKeychainCandidate(
        service: String,
        mode: ClaudeKeychainAccessMode
    ) -> KeychainCandidateResult {
        let decision = ClaudeKeychainPromptPolicy.decision(
            requestedMode: mode,
            deniedAt: denialStore.deniedAt(for: service),
            now: now()
        )
        guard case let .query(queryMode) = decision else {
            return .continueWalk(
                outcome: .interactionRequired,
                consumedInteractivePrompt: false
            )
        }

        switch readKeychainResult(service, queryMode) {
        case let .value(payload):
            denialStore.clearDenial(for: service)
            return payload.isEmpty
                ? .continueWalk(
                    outcome: .notFound,
                    consumedInteractivePrompt: queryMode == .interactive
                )
                : .value(payload)
        case .notFound:
            denialStore.clearDenial(for: service)
            return .continueWalk(outcome: .notFound, consumedInteractivePrompt: false)
        case .interactionRequired:
            denialStore.recordDenial(for: service, at: now())
            return .continueWalk(
                outcome: .interactionRequired,
                consumedInteractivePrompt: queryMode == .interactive
            )
        case .denied:
            denialStore.recordDenial(for: service, at: now())
            return .continueWalk(
                outcome: .denied,
                consumedInteractivePrompt: queryMode == .interactive
            )
        case let .failure(status):
            return .continueWalk(
                outcome: .failure(status),
                consumedInteractivePrompt: queryMode == .interactive
            )
        }
    }

    private static func mergedOutcome(
        existing: ClaudeKeychainReadOutcome<Data>,
        candidate: ClaudeKeychainReadOutcome<Data>
    ) -> ClaudeKeychainReadOutcome<Data> {
        if case .denied = candidate {
            return .denied
        }
        if case .notFound = existing {
            return candidate
        }
        return existing
    }

    static func keychainPayload(
        service: String,
        mode: ClaudeKeychainAccessMode,
        backend: KeychainBackend = SecItemKeychainBackend(),
        interaction: KeychainInteractionGate = LegacyKeychainInteractionGate()
    ) -> ClaudeKeychainReadOutcome<Data> {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let query = ClaudeKeychainQuery.applyingAccessMode(mode, to: baseQuery)

        // The query flags above cover LocalAuthentication only. The gate is what
        // keeps securityd's login-keychain ACL dialog off the screen for a
        // background probe — see `KeychainInteractionGate`. Gated here rather
        // than inside `SecItemKeychainBackend` so it applies to Claude's
        // externally-owned items alone; `KeychainManager` reads items MeterBar
        // wrote itself and is always inside their ACL.
        var result: AnyObject?
        let status = interaction.withUserInteraction(allowed: mode == .interactive) {
            backend.copyMatching(query: query, result: &result)
        }
        return ClaudeKeychainQuery.outcome(
            status: status,
            result: result as? Data,
            mode: mode
        )
    }

    static func filePayload(path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }
}
