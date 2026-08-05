import Foundation
import Security

/// Decides whether securityd may put a dialog on screen for one keychain
/// operation.
///
/// This exists because there are **two** independent interaction surfaces on a
/// keychain read, and MeterBar was only closing one of them:
///
/// 1. **LocalAuthentication** — biometrics / passcode for items protected by a
///    `kSecAccessControl`. Suppressed by `kSecUseAuthenticationUIFail` and
///    `LAContext.interactionNotAllowed`, which is what
///    `ClaudeKeychainQuery.applyingAccessMode` already sets.
/// 2. **The legacy login-keychain ACL dialog** — "MeterBar wants to use the
///    <item> key in your keychain", raised by securityd whenever a decrypting
///    read targets a generic password whose trusted-application list does not
///    include the caller. Claude Code writes its credentials item, so MeterBar
///    is not in that list. **Nothing in the `SecItem` query dictionary
///    suppresses this one.** Only the process-level interaction flag does.
///
/// That gap is the bug: `ClaudeCodeLocalService.init` probes credentials from a
/// detached task on every launch, so every launch raised the ACL dialog. Saying
/// "Always Allow" did not end it, because a *successful* password entry records
/// no denial and therefore suppresses nothing on the next launch, and because
/// the walk visits several candidate services, each with an independent ACL.
///
/// Measured on the affected machine: with the query flags alone a background
/// read blocked on the dialog until it was killed; with the process flag it
/// returned `errSecAuthFailed` in 12 ms and drew nothing.
///
/// Suppression blocks **UI, not access**. A caller already in the item's ACL
/// still gets the data silently, so granting access remains permanent and only
/// the unsolicited prompt disappears.
nonisolated protocol KeychainInteractionGate: Sendable {
    /// Runs `perform` with securityd interaction forced to `allowed`, restoring
    /// the prior process state afterwards. Deliberately non-generic over
    /// `OSStatus`: `perform` stays non-escaping so callers can write to an
    /// `inout` result buffer inside it.
    func withUserInteraction(allowed: Bool, perform: () -> OSStatus) -> OSStatus
}

/// Production gate, built on `SecKeychainSetUserInteractionAllowed`.
///
/// The API is deprecated (macOS 10.10) and warns at build time, which is
/// accepted on purpose: it is the only supported way to suppress the legacy ACL
/// dialog, it still functions on current macOS, and the modern
/// `kSecUseAuthenticationUI` family does not cover this surface. The warning is
/// the reminder to revisit if a replacement ever ships.
nonisolated struct LegacyKeychainInteractionGate: KeychainInteractionGate {
    /// The flag is process-global, so concurrent reads would otherwise stomp on
    /// each other's saved state — a background probe could leave interaction
    /// suppressed for a user-initiated refresh running beside it. Recursive so a
    /// nested read cannot deadlock against itself.
    private static let lock = NSRecursiveLock()

    /// Current process state, or nil when securityd will not report it.
    /// Exposed for tests, which assert the save/restore contract.
    static func currentUserInteractionAllowed() -> Bool? {
        var state: DarwinBoolean = true
        guard SecKeychainGetUserInteractionAllowed(&state) == errSecSuccess else { return nil }
        return state.boolValue
    }

    func withUserInteraction(allowed: Bool, perform: () -> OSStatus) -> OSStatus {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        // If either half of the save/restore pair is unavailable, run the
        // operation unwrapped rather than risk leaving the process in a state
        // that cannot be put back. Worst case is the pre-existing behaviour.
        guard let previous = Self.currentUserInteractionAllowed(),
              SecKeychainSetUserInteractionAllowed(allowed) == errSecSuccess else {
            return perform()
        }
        defer { _ = SecKeychainSetUserInteractionAllowed(previous) }

        return perform()
    }
}
