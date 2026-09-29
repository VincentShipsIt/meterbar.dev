import Foundation
import MeterBarShared

/// Read-only discovery of the official Kimi Code OAuth artifact.
///
/// Kimi Code stores its login under its data root — `KIMI_CODE_HOME`, default
/// `~/.kimi-code` — as `credentials/kimi-code.json` (mode 0600, snake_case).
/// Only that default managed slot is read: the client scopes credentials for
/// custom OAuth hosts and base URLs into `kimi-code-env-<hash>.json`, and those
/// belong to a different endpoint than the one MeterBar queries.
///
/// The token is never logged, copied, or written anywhere. Refresh stays with
/// Kimi Code: an expired token is reported as such and the user is sent back to
/// `/login`, because MeterBar has no safe way to rotate a refresh token the
/// official client also owns.
nonisolated enum KimiCodeCredentialReader {
    enum Result: Equatable {
        case notFound
        case token(String)
        case expired
        case unreadable

        /// The redaction-safe outcome shared with readiness reporting.
        var probe: KimiCodeCredentialProbe {
            switch self {
            case .notFound: return .notFound
            case .token: return .ready
            case .expired: return .expired
            case .unreadable: return .unreadable
            }
        }
    }

    /// A credential file has no reason to be large; refusing anything bigger
    /// keeps a mis-pointed `KIMI_CODE_HOME` from being slurped into memory.
    private static let maximumFileSize = 64 * 1_024

    static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> String {
        guard let rawValue = environment["KIMI_CODE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty else {
            return (realHomeDirectory as NSString).appendingPathComponent(".kimi-code")
        }
        return ServiceSupport.expandUserPath(rawValue, realHomeDirectory: realHomeDirectory)
    }

    static func credentialFilePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> String {
        let root = directory(environment: environment, realHomeDirectory: realHomeDirectory)
        return ((root as NSString).appendingPathComponent("credentials") as NSString)
            .appendingPathComponent("kimi-code.json")
    }

    /// Cheap existence probe for the synchronous access check. It does not
    /// open the file, so nothing secret is read on the main actor.
    static func credentialFileExists(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory(),
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(
            atPath: credentialFilePath(environment: environment, realHomeDirectory: realHomeDirectory)
        )
    }

    static func read(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory(),
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Result {
        let path = credentialFilePath(environment: environment, realHomeDirectory: realHomeDirectory)
        guard fileManager.fileExists(atPath: path) else { return .notFound }

        // A symlink or special file is not something Kimi Code writes, and
        // following one could read an unrelated file's bytes into a request.
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? 0 <= maximumFileSize,
              let data = fileManager.contents(atPath: path),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = (object["access_token"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return .unreadable
        }

        // `expires_at` is Unix seconds. Absent or zero means "unknown": like a
        // malformed JWT, that is not evidence of expiry, so the server's 401
        // stays the source of truth.
        if let expiresAt = (object["expires_at"] as? NSNumber)?.doubleValue,
           expiresAt > 0,
           expiresAt <= now.timeIntervalSince1970 {
            return .expired
        }
        return .token(token)
    }
}
