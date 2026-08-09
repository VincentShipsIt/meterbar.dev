import Darwin
import Foundation
import Security

/// Where the bearer token protecting `meterbar serve` came from. Callers use
/// this provenance to decide whether startup may reveal the token: only a
/// freshly generated token has nowhere else for the operator to retrieve it.
nonisolated public enum ServeTokenOrigin: Sendable, Equatable {
    case explicitArgument
    case file
    case environment
    case generated
}

/// A usable bearer token paired with the source that won the documented
/// precedence chain.
nonisolated public struct ResolvedServeToken: Sendable, Equatable {
    public let token: String
    public let origin: ServeTokenOrigin

    public init(token: String, origin: ServeTokenOrigin) {
        self.token = token
        self.origin = origin
    }
}

/// Operator-actionable failures from token-source resolution. Keeping these
/// cases typed lets the CLI translate them into concise `ValidationError`
/// messages without parsing filesystem error copy or exposing token values.
nonisolated public enum ServeTokenResolutionError: Error, Sendable, Equatable {
    case blankExplicitArgument
    case unreadableTokenFile(path: String)
    case blankTokenFile(path: String)
    case blankEnvironment
}

/// Pure precedence and validation policy for the `meterbar serve` bearer
/// token. Filesystem reads and token generation are injected so every branch
/// is deterministic in tests and no test ever needs to place a secret on disk.
nonisolated public enum ServeTokenSource {
    public static let environmentVariable = "METERBAR_SERVE_TOKEN"

    public static func resolve(
        explicitToken: String?,
        tokenFilePath: String?,
        environment: [String: String],
        readFile: (String) throws -> String,
        generate: () -> String
    ) throws -> ResolvedServeToken {
        if let explicitToken {
            guard ServeToken.isUsable(explicitToken) else {
                throw ServeTokenResolutionError.blankExplicitArgument
            }
            return ResolvedServeToken(token: explicitToken, origin: .explicitArgument)
        }

        if let tokenFilePath {
            let contents: String
            do {
                contents = try readFile(tokenFilePath)
            } catch {
                throw ServeTokenResolutionError.unreadableTokenFile(path: tokenFilePath)
            }
            let token = trimmingTrailingWhitespace(from: contents)
            guard ServeToken.isUsable(token) else {
                throw ServeTokenResolutionError.blankTokenFile(path: tokenFilePath)
            }
            return ResolvedServeToken(token: token, origin: .file)
        }

        if let environmentToken = environment[environmentVariable] {
            guard ServeToken.isUsable(environmentToken) else {
                throw ServeTokenResolutionError.blankEnvironment
            }
            return ResolvedServeToken(token: environmentToken, origin: .environment)
        }

        return ResolvedServeToken(token: generate(), origin: .generated)
    }

    /// Token files commonly end in a newline because they were written by a
    /// shell or secret manager. Strip only the suffix: leading and internal
    /// whitespace may deliberately be part of the bearer token and must remain
    /// byte-for-byte intact.
    private static func trimmingTrailingWhitespace(from value: String) -> String {
        var end = value.endIndex
        while end > value.startIndex {
            let previous = value.index(before: end)
            let character = value[previous]
            guard character.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains) else {
                break
            }
            end = previous
        }
        return String(value[..<end])
    }
}

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
