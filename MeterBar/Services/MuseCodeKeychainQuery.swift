import Foundation
import Security

/// Read-only lookup of the Muse CLI generic-password item.
///
/// Service `ai.meta.dev.credentials`, account `meta`. The secret belongs to
/// the Muse CLI, so MeterBar is not on its ACL. Background refresh uses a
/// no-UI query and never prompts. The macOS prompt is reserved for Connect
/// Muse Code. Unit tests build the query dictionary; they do not call
/// `SecItemCopyMatching`.
nonisolated enum MuseCodeKeychainQuery {
    static let service = "ai.meta.dev.credentials"
    static let account = "meta"

    static func dictionary(mode: ClaudeKeychainAccessMode) -> [String: Any] {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return ClaudeKeychainQuery.applyingAccessMode(mode, to: base)
    }

    /// Background mode sets `kSecUseAuthenticationUIFail` and, through `gate`,
    /// forces `SecKeychainSetUserInteractionAllowed(false)` for the copy. The
    /// query flag alone does not suppress the legacy ACL dialog.
    static func read(
        mode: ClaudeKeychainAccessMode,
        gate: KeychainInteractionGate = LegacyKeychainInteractionGate(),
        copy: (CFDictionary) -> (OSStatus, Data?) = secureCopy
    ) -> ClaudeKeychainReadOutcome<Data> {
        let query = dictionary(mode: mode) as CFDictionary
        var payload: Data?
        let status = gate.withUserInteraction(allowed: mode == .interactive) {
            let (status, data) = copy(query)
            payload = data
            return status
        }
        return ClaudeKeychainQuery.outcome(status: status, result: payload, mode: mode)
    }

    private static func secureCopy(_ query: CFDictionary) -> (OSStatus, Data?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query, &item)
        return (status, item as? Data)
    }
}
