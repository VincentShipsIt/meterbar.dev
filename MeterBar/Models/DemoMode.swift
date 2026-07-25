import Foundation

/// The single source of truth for whether demo / sample-data mode is active.
///
/// Demo mode swaps the signed-in owner's real usage for the synthetic
/// `DemoData` fixture so the landing-page screenshots and the first-run
/// onboarding preview render a populated, on-message MeterBar without exposing
/// real costs or private project names. It is **off by default** and, when on,
/// only changes what the singletons publish at construction — it never reads or
/// writes real cached data, so real users are unaffected.
///
/// Two independent opt-ins, checked at `.shared` construction time:
///  - the `METERBAR_DEMO` launch environment variable (`1`/`true`/`yes`/`on`),
///    used by the screenshot tooling and CI; or
///  - the hidden `StorageKeys.demoMode` preference, for a manual toggle.
///
/// `isEnabled(environment:defaults:)` is pure and injectable so the gate is unit
/// tested without touching the process environment or standard defaults.
nonisolated enum DemoMode {
    /// Launch environment variable that forces demo mode on.
    static let environmentKey = "METERBAR_DEMO"

    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if let raw = environment[environmentKey], isTruthy(raw) {
            return true
        }
        return defaults.bool(forKey: StorageKeys.demoMode)
    }

    /// Resolved once against the real process environment and standard defaults.
    /// Read by the `.shared` singletons that own the demo data seams.
    static var isActive: Bool { isEnabled() }

    private static func isTruthy(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}
