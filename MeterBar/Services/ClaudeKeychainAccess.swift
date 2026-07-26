import Foundation
import LocalAuthentication
import Security

/// Whether a Claude credential read is allowed to involve the user.
///
/// Background is deliberately the default at every call site. Interactive
/// access is reserved for an explicit refresh/menu action.
nonisolated enum ClaudeKeychainAccessMode: Equatable, Sendable {
    case background
    case interactive

    init(trigger: ClaudeTokenRefreshTrigger) {
        self = trigger == .userInitiated ? .interactive : .background
    }
}

nonisolated enum ClaudeKeychainPromptDecision: Equatable, Sendable {
    case skipKeychain
    case query(ClaudeKeychainAccessMode)
}

/// Pure policy for suppressing repeated background Keychain authorization
/// attempts after macOS reports that interaction would be required.
nonisolated enum ClaudeKeychainPromptPolicy {
    static let denialCooldown: TimeInterval = 6 * 60 * 60

    static func decision(
        requestedMode: ClaudeKeychainAccessMode,
        deniedAt: Date?,
        now: Date
    ) -> ClaudeKeychainPromptDecision {
        if requestedMode == .interactive {
            return .query(.interactive)
        }
        guard let deniedAt, deniedAt <= now else {
            return .query(.background)
        }
        return now < deniedAt.addingTimeInterval(denialCooldown)
            ? .skipKeychain
            : .query(.background)
    }
}

/// Secret-free result of a Keychain query. Keeping the Security status classes
/// distinct lets the candidate walker suppress prompts without confusing an
/// authorization barrier with a genuinely absent credential.
nonisolated enum ClaudeKeychainReadOutcome<Value: Sendable>: Sendable {
    case value(Value)
    case notFound
    case interactionRequired
    case denied
    case failure(OSStatus)
}

extension ClaudeKeychainReadOutcome: Equatable where Value: Equatable {}

nonisolated enum ClaudeKeychainQuery {
    static func applyingAccessMode(
        _ mode: ClaudeKeychainAccessMode,
        to query: [String: Any]
    ) -> [String: Any] {
        guard mode == .background else { return query }

        var noUIQuery = query
        let context = LAContext()
        context.interactionNotAllowed = true
        noUIQuery[kSecUseAuthenticationContext as String] = context
        noUIQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return noUIQuery
    }

    static func outcome<Value: Sendable>(
        status: OSStatus,
        result: Value?,
        mode: ClaudeKeychainAccessMode
    ) -> ClaudeKeychainReadOutcome<Value> {
        switch status {
        case errSecSuccess:
            return result.map(ClaudeKeychainReadOutcome.value) ?? .failure(errSecInternalError)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            return .interactionRequired
        case errSecUserCanceled:
            return .denied
        case errSecAuthFailed:
            return mode == .background ? .interactionRequired : .denied
        default:
            return .failure(status)
        }
    }
}

/// Persisted, per-service suppression state. Only a Keychain service name and
/// timestamp are stored; credential payloads never enter UserDefaults.
nonisolated final class ClaudeKeychainDenialStore: @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let lock = NSLock()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func deniedAt(for service: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return records()[service]
    }

    func recordDenial(for service: String, at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        var updated = records()
        updated[service] = date
        persist(updated)
    }

    func clearDenial(for service: String) {
        lock.lock()
        defer { lock.unlock() }
        var updated = records()
        updated.removeValue(forKey: service)
        persist(updated)
    }

    private func records() -> [String: Date] {
        guard let data = userDefaults.data(forKey: StorageKeys.claudeCodeKeychainDenials),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func persist(_ records: [String: Date]) {
        guard !records.isEmpty else {
            userDefaults.removeObject(forKey: StorageKeys.claudeCodeKeychainDenials)
            return
        }
        if let data = try? JSONEncoder().encode(records) {
            userDefaults.set(data, forKey: StorageKeys.claudeCodeKeychainDenials)
        }
    }
}
