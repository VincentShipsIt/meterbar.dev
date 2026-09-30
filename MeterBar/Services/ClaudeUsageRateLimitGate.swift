import Foundation

/// Backs off `/api/oauth/usage` after an HTTP 429.
///
/// The endpoint rate-limits aggressively. Polling it again on the next cycle
/// keeps it limited, so every refresh fails and the card sits on the last good
/// reading — with a reset time that has already passed. While a cooldown is
/// active the refresh is skipped without a request, and it fails the same way a
/// live 429 does, so the last good data stays on screen.
///
/// Keyed by a one-way hash of the bearer token so each Claude profile has its
/// own cooldown and no credential is held as a dictionary key.
nonisolated final class ClaudeUsageRateLimitGate: @unchecked Sendable {
    // MARK: Internal

    static let shared = ClaudeUsageRateLimitGate()

    /// Used when a 429 carries no usable `Retry-After`.
    static let defaultCooldown: TimeInterval = 5 * 60
    /// A hostile or broken header must not park the provider for hours.
    static let maximumCooldown: TimeInterval = 30 * 60

    /// Seconds from a `Retry-After` header (delta-seconds or HTTP-date), clamped
    /// to `1...maximumCooldown`; `defaultCooldown` when absent or unreadable.
    static func cooldown(retryAfter header: String?, now: Date = Date()) -> TimeInterval {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else {
            return defaultCooldown
        }
        let seconds: TimeInterval
        if let delta = TimeInterval(header) {
            seconds = delta
        } else if let date = httpDate(header) {
            seconds = date.timeIntervalSince(now)
        } else {
            return defaultCooldown
        }
        guard seconds.isFinite else {
            return defaultCooldown
        }
        return min(max(seconds, 1), maximumCooldown)
    }

    func recordRateLimit(token: String, retryAfter header: String?, now: Date = Date()) {
        let until = now.addingTimeInterval(Self.cooldown(retryAfter: header, now: now))
        lock.lock()
        blockedUntil[Self.key(token)] = until
        lock.unlock()
    }

    /// The end of the active cooldown for `token`, or `nil` when it may fetch.
    func cooldownEnd(token: String, now: Date = Date()) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.key(token)
        guard let until = blockedUntil[key] else {
            return nil
        }
        guard until > now else {
            blockedUntil[key] = nil
            return nil
        }
        return until
    }

    func clear(token: String) {
        lock.lock()
        blockedUntil[Self.key(token)] = nil
        lock.unlock()
    }

    // MARK: Private

    private let lock = NSLock()
    private var blockedUntil: [Int: Date] = [:]

    private static func key(_ token: String) -> Int {
        var hasher = Hasher()
        hasher.combine(token)
        return hasher.finalize()
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}
