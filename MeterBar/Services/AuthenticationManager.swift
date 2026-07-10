import Combine
import Foundation

/// Holds the organization API admin keys (Anthropic / OpenAI) the user enters
/// in Settings, persisted in the Keychain. These gate the API-usage cards.
final class AuthenticationManager: ObservableObject {
    static let shared = AuthenticationManager()

    @Published var claudeAdminKey: String?
    @Published var openaiAdminKey: String?

    private let keychain: KeychainManager

    private convenience init() {
        self.init(keychain: .shared)
    }

    /// Injectable for Keychain failure-path tests; production uses `shared`.
    init(keychain: KeychainManager) {
        self.keychain = keychain
        claudeAdminKey = keychain.get(key: ApiProvider.anthropic.keychainKey)
        openaiAdminKey = keychain.get(key: ApiProvider.openai.keychainKey)
    }

    func adminKey(for provider: ApiProvider) -> String? {
        switch provider {
        case .anthropic: return claudeAdminKey
        case .openai: return openaiAdminKey
        }
    }

    func isAuthenticated(_ provider: ApiProvider) -> Bool {
        adminKey(for: provider) != nil
    }

    @discardableResult
    func setAdminKey(_ key: String, for provider: ApiProvider) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let success = keychain.save(key: provider.keychainKey, value: trimmed)
        if success {
            switch provider {
            case .anthropic: claudeAdminKey = trimmed
            case .openai: openaiAdminKey = trimmed
            }
        }
        return success
    }

    @discardableResult
    func removeAdminKey(for provider: ApiProvider) -> Bool {
        let deleted = keychain.delete(key: provider.keychainKey)
        let remainingValue = deleted ? nil : keychain.get(key: provider.keychainKey)
        switch provider {
        case .anthropic: claudeAdminKey = remainingValue
        case .openai: openaiAdminKey = remainingValue
        }
        return deleted
    }

    var isClaudeAuthenticated: Bool { claudeAdminKey != nil }
    var isOpenAIAuthenticated: Bool { openaiAdminKey != nil }
}
