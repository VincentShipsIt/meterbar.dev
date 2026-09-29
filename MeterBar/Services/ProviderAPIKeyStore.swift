import Foundation

/// One provider's user-supplied API key, held in the Keychain.
///
/// The single-key providers (Kimi Code, Z.ai, GitHub Copilot) each repeated the
/// same four operations against `KeychainManager`, so they share this instead
/// of restating trim-then-save and the prompt-free existence probe. OpenRouter
/// keeps its own multi-key service: it stores one item per managed account.
nonisolated struct ProviderAPIKeyStore {
    let keychainKey: String
    private let keychain: KeychainManager

    init(keychainKey: String, keychain: KeychainManager = .shared) {
        self.keychainKey = keychainKey
        self.keychain = keychain
    }

    /// Attribute-only probe: never decrypts, so it cannot raise a Keychain
    /// prompt and is safe to call on the main actor.
    var hasKey: Bool {
        keychain.hasKey(key: keychainKey)
    }

    func key() -> String? {
        keychain.get(key: keychainKey)
    }

    /// Saves the trimmed value. An empty value is rejected rather than stored.
    @discardableResult
    func save(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return keychain.save(key: keychainKey, value: trimmed)
    }

    @discardableResult
    func remove() -> Bool {
        keychain.delete(key: keychainKey)
    }
}
