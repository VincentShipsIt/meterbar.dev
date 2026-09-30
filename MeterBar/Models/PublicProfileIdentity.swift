import Foundation

/// A public profile's own identity: a slug for the URL and a secret key that
/// authorizes writes to it.
///
/// This is deliberately not the iCloud `deviceID`. That UUID names the user's
/// private CloudKit zone and is re-minted when a Mac is cloned, so it can
/// neither be shown in a URL nor be reset without disturbing private data.
nonisolated struct PublicProfileIdentity: Equatable, Sendable {
    let slug: String
    let publishKey: String

    /// Crockford base32, lowercase: no `i l o u`, so a slug read aloud or off a
    /// card survives being typed back.
    private static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
    static let slugLength = 10
    static let keyByteCount = 32

    static func isValidSlug(_ candidate: String) -> Bool {
        candidate.count == slugLength && candidate.allSatisfy(alphabet.contains)
    }

    /// 50 bits of the system CSPRNG. Not a secret (the profile is public), just
    /// unguessable enough that URLs cannot be enumerated.
    static func mint() -> PublicProfileIdentity {
        var generator = SystemRandomNumberGenerator()
        let slug = String((0..<slugLength).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
        let key = Data((0..<keyByteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return PublicProfileIdentity(slug: slug, publishKey: base64URL(key))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func profileURL(slug: String, base: URL = PublicProfileEndpoint.defaultBaseURL) -> URL {
        base.appendingPathComponent("u").appendingPathComponent(slug)
    }
}

// MARK: - PublicProfileEndpoint

nonisolated enum PublicProfileEndpoint {
    static let defaultBaseURL: URL = {
        guard let url = URL(string: "https://meterbar.dev") else {
            preconditionFailure("the literal profile host is a valid URL")
        }
        return url
    }()

    /// `METERBAR_PROFILE_BASE_URL` points a debug build at a local site. It is
    /// ignored in release builds, so an environment variable cannot redirect a
    /// shipped app's profile to another host.
    static var baseURL: URL {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["METERBAR_PROFILE_BASE_URL"],
           let url = URL(string: raw), url.scheme != nil {
            return url
        }
        #endif
        return defaultBaseURL
    }

    static func apiURL(slug: String, base: URL = baseURL) -> URL {
        base.appendingPathComponent("api").appendingPathComponent("profile").appendingPathComponent(slug)
    }
}

// MARK: - PublicProfilePublishPolicy

/// When a live profile is allowed to touch the network.
///
/// The app makes no request at all until the user opts in; after that this is
/// the whole budget: at most one attempt per `minimumInterval`, spent only when
/// the content changed or the hourly heartbeat is due. The server drops a
/// profile a week after its last write, so the heartbeat has slack.
nonisolated enum PublicProfilePublishPolicy {
    static let minimumInterval: TimeInterval = 15 * 60
    static let heartbeatInterval: TimeInterval = 60 * 60

    static func shouldPublish(
        now: Date,
        lastAttempt: Date?,
        lastSuccess: Date?,
        contentChanged: Bool,
        force: Bool = false
    ) -> Bool {
        if force { return true }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < minimumInterval { return false }
        guard let lastSuccess else { return true }
        return contentChanged || now.timeIntervalSince(lastSuccess) >= heartbeatInterval
    }
}
