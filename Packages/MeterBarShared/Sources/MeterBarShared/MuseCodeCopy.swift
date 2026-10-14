import Foundation

/// Authored Muse Code sentences shared by the card, settings, and readiness.
///
/// These stay here, not inside `ServiceError`, because the error sanitizer
/// drops any message it did not already allow. The words are the product
/// contract for each support state.
public enum MuseCodeCopy {
    public static let notSignedIn = "Not signed in. Run `muse login`."
    public static let needsConnect =
        "Connect Muse Code in Settings. When macOS asks for Keychain access, choose Always Allow."
    public static let needsKeychainAccess =
        "MeterBar needs Keychain access to the Muse CLI login. "
        + "In Settings, choose Connect Muse Code and select Always Allow. "
        + "A fresh `muse login` recreates the item and may require allowing access again."
    public static let rejectedToken = "The saved Muse CLI token is not a Muse Code sign-in. Run `muse login`."
    public static let reconnect = "Muse Code rejected the sign-in. Run `muse login`."
    public static let noSubscription = "No Muse Code subscription. Pay-as-you-go has no quota bar."
    public static let paymentRequired = "Muse Code billing is incomplete."
    public static let unreadable = "The Muse CLI sign-in could not be read. Run `muse login`."
    /// No trailing period. An idle window is not 0% and not an error.
    public static let idle = "Window idle, usage not reported"
    public static let setupPrompt = "Connect Muse Code"

    /// `timestamp` is an ISO-8601 internet date in UTC, the last good reading's
    /// `lastUpdated`. The sentence is the card header while those bars remain.
    public static func asOf(_ timestamp: String) -> String {
        "Window idle, usage not reported. As of \(timestamp)."
    }
}
