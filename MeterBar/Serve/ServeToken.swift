import Darwin
import Foundation
import Security

/// Bearer token generation and comparison for `meterbar serve`. Comparison
/// runs in constant time so a network caller can't use response latency to
/// guess the token one byte at a time (docs/cli-json-schema.md security notes).
nonisolated public enum ServeToken {
    private static let byteCount = 32
    private static let bearerPrefix = "Bearer "

    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, byteCount, baseAddress)
        }
        if status != errSecSuccess {
            // SecRandomCopyBytes practically never fails on Apple platforms;
            // arc4random_buf is still a CSPRNG, so this keeps token
            // generation from crashing the process rather than degrading it.
            arc4random_buf(&bytes, byteCount)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a token is strong enough to gate anything. A blank token would
    /// otherwise compare equal to the empty string a caller gets from a bare
    /// `Authorization: Bearer ` header, turning the auth check into a no-op.
    public static func isUsable(_ token: String) -> Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `presented` is the raw `Authorization` header value. Anything other
    /// than an exact `Bearer <token>` shape fails without a byte comparison.
    ///
    /// An unusable `expected` fails closed: callers are expected to reject a
    /// blank token before binding a socket (`ServeCLI.run`), and this is the
    /// second layer that keeps a missed check from opening the endpoint.
    public static func matches(presented: String?, expected: String) -> Bool {
        guard isUsable(expected) else { return false }
        guard let presented, presented.hasPrefix(bearerPrefix) else { return false }
        let candidate = String(presented.dropFirst(bearerPrefix.count))
        return constantTimeEquals(candidate, expected)
    }

    /// Always walks the full length of the longer input — no early return on
    /// a length or byte mismatch — so equal-length-but-wrong tokens and
    /// wrong-length tokens take the same code path.
    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        var difference: UInt8 = lhsBytes.count == rhsBytes.count ? 0 : 1
        for index in 0..<max(lhsBytes.count, rhsBytes.count) {
            let lhsByte = index < lhsBytes.count ? lhsBytes[index] : 0
            let rhsByte = index < rhsBytes.count ? rhsBytes[index] : 0
            difference |= lhsByte ^ rhsByte
        }
        return difference == 0
    }
}
