import Foundation
import Security

nonisolated struct AccountCredentialSwitch: Equatable, Sendable {
    let provider: AccountFailoverProvider
    let fromAccountID: UUID
    let toAccountID: UUID
}

/// The sole mutation seam for provider-owned credential stores. Coordinator
/// tests inject a recorder, so unit tests never read or write the real Keychain.
protocol AccountCredentialSwitching {
    func switchCredentials(
        provider: AccountFailoverProvider,
        from: UUID,
        to: UUID
    ) async throws
}

nonisolated enum CredentialExchangeError: Error, Equatable {
    case sameLocation
    case missingSourceCredential
    case missingTargetCredential
    case rollbackFailed
}

/// Provider-neutral two-store exchange. Both payloads are read before either
/// write, and a failed second write restores the first location. The algorithm
/// never creates a backup file or another plaintext copy.
nonisolated enum CredentialExchangeTransaction {
    static func exchange<Location: Hashable & Sendable>(
        source: Location,
        target: Location,
        read: (Location) throws -> Data?,
        write: (Location, Data) throws -> Void
    ) throws {
        guard source != target else { throw CredentialExchangeError.sameLocation }
        guard let sourcePayload = try read(source), !sourcePayload.isEmpty else {
            throw CredentialExchangeError.missingSourceCredential
        }
        guard let targetPayload = try read(target), !targetPayload.isEmpty else {
            throw CredentialExchangeError.missingTargetCredential
        }

        try write(source, targetPayload)
        do {
            try write(target, sourcePayload)
        } catch {
            do {
                try write(source, sourcePayload)
            } catch {
                throw CredentialExchangeError.rollbackFailed
            }
            throw error
        }
    }
}

@MainActor
final class LiveAccountCredentialSwitcher: AccountCredentialSwitching {
    static let shared = LiveAccountCredentialSwitcher()

    private let claudeAccounts: ClaudeCodeAccountStore
    private let codexAccounts: CodexAccountStore

    init(
        claudeAccounts: ClaudeCodeAccountStore? = nil,
        codexAccounts: CodexAccountStore? = nil
    ) {
        self.claudeAccounts = claudeAccounts ?? .shared
        self.codexAccounts = codexAccounts ?? .shared
    }

    func switchCredentials(
        provider: AccountFailoverProvider,
        from sourceID: UUID,
        to targetID: UUID
    ) async throws {
        switch provider {
        case .claudeCode:
            guard let source = claudeAccounts.enabledAccounts.first(where: { $0.id == sourceID }),
                  let target = claudeAccounts.enabledAccounts.first(where: { $0.id == targetID }) else {
                throw LiveCredentialExchangeError.accountUnavailable
            }
            try await Task.detached(priority: .userInitiated) {
                try LiveCredentialExchange.exchangeClaude(source: source, target: target)
            }.value
            guard claudeAccounts.exchangeCredentialLocations(
                from: sourceID,
                to: targetID,
                expectedSource: source.configDirectory,
                expectedTarget: target.configDirectory
            ) else {
                try await restoreClaudeExchange(source: source, target: target)
                throw LiveCredentialExchangeError.accountConfigurationChanged
            }
        case .codexCli:
            guard let source = codexAccounts.enabledAccounts.first(where: { $0.id == sourceID }),
                  let target = codexAccounts.enabledAccounts.first(where: { $0.id == targetID }) else {
                throw LiveCredentialExchangeError.accountUnavailable
            }
            try await Task.detached(priority: .userInitiated) {
                try LiveCredentialExchange.exchangeCodex(source: source, target: target)
            }.value
            guard codexAccounts.exchangeCredentialLocations(
                from: sourceID,
                to: targetID,
                expectedSource: source.homeDirectory,
                expectedTarget: target.homeDirectory
            ) else {
                try await restoreCodexExchange(source: source, target: target)
                throw LiveCredentialExchangeError.accountConfigurationChanged
            }
        }
    }

    private func restoreClaudeExchange(source: ClaudeCodeAccount, target: ClaudeCodeAccount) async throws {
        do {
            try await Task.detached(priority: .userInitiated) {
                try LiveCredentialExchange.exchangeClaude(source: source, target: target)
            }.value
        } catch {
            throw LiveCredentialExchangeError.rollbackFailed
        }
    }

    private func restoreCodexExchange(source: CodexAccount, target: CodexAccount) async throws {
        do {
            try await Task.detached(priority: .userInitiated) {
                try LiveCredentialExchange.exchangeCodex(source: source, target: target)
            }.value
        } catch {
            throw LiveCredentialExchangeError.rollbackFailed
        }
    }
}

nonisolated private enum LiveCredentialExchangeError: Error {
    case accountUnavailable
    case accountConfigurationChanged
    case keychainWriteFailed(OSStatus)
    case rollbackFailed
}

nonisolated private enum ClaudeCredentialLocation: Hashable, Sendable {
    case keychain(service: String)
    case file(path: String)
}

/// Exchanges only provider-native credential locations. No backup artifact,
/// UserDefaults payload, or log entry ever receives credential bytes.
nonisolated private enum LiveCredentialExchange {
    static func exchangeCodex(source: CodexAccount, target: CodexAccount) throws {
        let sourceURL = URL(fileURLWithPath: CodexHomeDirectory.authFilePath(for: source))
        let targetURL = URL(fileURLWithPath: CodexHomeDirectory.authFilePath(for: target))
        try CredentialExchangeTransaction.exchange(
            source: sourceURL,
            target: targetURL,
            read: { try? Data(contentsOf: $0) },
            write: { try SecureFileWriter.write($1, to: $0) }
        )
    }

    static func exchangeClaude(source: ClaudeCodeAccount, target: ClaudeCodeAccount) throws {
        let sourceLocation = try resolvedClaudeLocation(for: source)
        let targetLocation = try resolvedClaudeLocation(for: target)
        try CredentialExchangeTransaction.exchange(
            source: sourceLocation,
            target: targetLocation,
            read: readClaudeCredential,
            write: writeClaudeCredential
        )
    }

    private static func resolvedClaudeLocation(for account: ClaudeCodeAccount) throws -> ClaudeCredentialLocation {
        for candidate in ClaudeCredentialResolver.candidates(for: account) {
            let location: ClaudeCredentialLocation
            switch candidate {
            case let .keychain(service): location = .keychain(service: service)
            case let .file(path): location = .file(path: path)
            }
            if let payload = try readClaudeCredential(location), !payload.isEmpty {
                return location
            }
        }
        throw CredentialExchangeError.missingSourceCredential
    }

    private static func readClaudeCredential(_ location: ClaudeCredentialLocation) throws -> Data? {
        switch location {
        case let .keychain(service):
            guard case let .value(payload) = ClaudeCredentialStore.keychainPayload(
                service: service,
                mode: .background
            ) else {
                return nil
            }
            return payload
        case let .file(path):
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }
    }

    private static func writeClaudeCredential(_ location: ClaudeCredentialLocation, payload: Data) throws {
        switch location {
        case let .keychain(service):
            let backend = SecItemKeychainBackend()
            let interaction = LegacyKeychainInteractionGate()
            let query = ClaudeKeychainQuery.applyingAccessMode(
                .background,
                to: [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                ]
            )
            let status = interaction.withUserInteraction(allowed: false) {
                backend.update(
                    query: query,
                    attributes: [kSecValueData as String: payload]
                )
            }
            guard status == errSecSuccess else {
                throw LiveCredentialExchangeError.keychainWriteFailed(status)
            }
        case let .file(path):
            try SecureFileWriter.write(payload, to: URL(fileURLWithPath: path))
        }
    }
}
