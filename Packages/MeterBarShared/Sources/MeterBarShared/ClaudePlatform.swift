import Foundation

/// What MeterBar can honestly say about a Claude Console session.
///
/// The Console's billing endpoints answer for the signed-in member, so an
/// unusual account gets a precise state instead of a refresh failure or a
/// guessed balance. The raw value is a stable, secret-free token persisted for
/// the CLI's `doctor`.
public enum ClaudePlatformAccountSupport: String, Codable, Sendable, Equatable {
    /// An API organization's credit balance is readable.
    case readable
    /// The session belongs to an account with no Console API organization
    /// (only Claude.ai chat organizations).
    case noAPIOrganization
    /// Every API organization answered 403: the member lacks billing access.
    case billingAccessDenied

    public var isReadable: Bool { self == .readable }

    /// Authored copy; never provider text.
    public var message: String {
        switch self {
        case .readable:
            return "Console API credit is readable."
        case .noAPIOrganization:
            return "This Claude account has no Console API organization. Create one at platform.claude.com."
        case .billingAccessDenied:
            return "Claude Console billing access was denied. Ask the organization owner for billing access."
        }
    }
}
