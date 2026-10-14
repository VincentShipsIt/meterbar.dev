import Foundation
import MeterBarShared

/// Bytes of the Muse CLI login file, or why they were not read.
enum MuseCodeAuthLoad: Equatable, Sendable {
    case missing
    case unreadable
    case data(Data)
}

/// Read-only discovery of the Muse CLI login.
///
/// The Muse CLI owns login and refresh. MeterBar never writes `auth.json` or
/// the Keychain item. An inline `providers.meta.access_token` wins and must
/// start with `dca:`. Otherwise the generic-password item
/// `ai.meta.dev.credentials` / `meta` is read, and only its `access_token` is
/// used — `api_key` is an inference key and is ignored.
///
/// A disabled provider returns `.disabled` before the file or the Keychain is
/// touched. Background reads pass `.background` and cannot present UI.
nonisolated enum MuseCodeCredentialReader {
    static let maximumFileSize = 64 * 1_024
    static let defaultRelativePath = ".config/muse/auth.json"
    private static let deviceCodePrefix = "dca:"

    struct Context: Sendable {
        var enabled: Bool
        var environment: [String: String]
        var realHomeDirectory: String
        var accessMode: ClaudeKeychainAccessMode
        var loadAuth: @Sendable (String) -> MuseCodeAuthLoad
        var keychain: @Sendable (ClaudeKeychainAccessMode) -> ClaudeKeychainReadOutcome<Data>
    }

    enum Result: Equatable, Sendable {
        case disabled
        case notSignedIn
        case token(String)
        case rejectedToken
        case needsKeychainAccess
        case needsConnect
        case noSubscription
        case unreadable

        var probe: MuseCodeCredentialProbe {
            switch self {
            case .disabled: return .disabled
            case .notSignedIn: return .notSignedIn
            case .token: return .ready
            case .rejectedToken: return .rejectedToken
            case .needsKeychainAccess: return .needsKeychainAccess
            case .needsConnect: return .needsConnect
            case .noSubscription: return .noSubscription
            case .unreadable: return .unreadable
            }
        }
    }

    static func read(_ context: Context) -> Result {
        guard context.enabled else { return .disabled }
        let path = authFilePath(
            environment: context.environment,
            realHomeDirectory: context.realHomeDirectory
        )
        switch context.loadAuth(path) {
        case .missing:
            return .notSignedIn
        case .unreadable:
            return .unreadable
        case let .data(data):
            return interpret(data, context: context)
        }
    }

    static func authFilePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> String {
        let override = environment["MUSE_AUTH_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty {
            return ServiceSupport.expandUserPath(override, realHomeDirectory: realHomeDirectory)
        }
        return (realHomeDirectory as NSString).appendingPathComponent(defaultRelativePath)
    }

    /// Refuses a symlink at the final path, a non-regular file, and anything
    /// larger than `maximumFileSize`. `attributesOfItem` follows links, so the
    /// symlink check uses `destinationOfSymbolicLink` instead.
    static func loadAuthFile(at path: String) -> MuseCodeAuthLoad {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
            return .unreadable
        }
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.int64Value >= 0,
              size.int64Value <= Int64(maximumFileSize),
              let data = FileManager.default.contents(atPath: path),
              data.count <= maximumFileSize else {
            return .unreadable
        }
        return .data(data)
    }

    // MARK: - File contents

    private static func interpret(_ data: Data, context: Context) -> Result {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unreadable
        }
        guard let meta = (root["providers"] as? [String: Any])?["meta"] as? [String: Any] else {
            return .notSignedIn
        }
        if meta.keys.contains("access_token") {
            guard let token = deviceCodeToken(meta["access_token"]) else { return .rejectedToken }
            return .token(token)
        }
        let mechanism = (meta["mechanism"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard mechanism == "oauth" else { return .notSignedIn }
        // A numeric 0/1 is not a JSON bool. Ignore it and still read the Keychain.
        if let active = jsonBool(meta["subs_active"]), !active {
            return .noSubscription
        }
        return keychainResult(context.keychain(context.accessMode))
    }

    /// `dca:` plus a payload. A blank, non-string, or prefix-only value is not
    /// a device-code token and does not fall through to the Keychain.
    private static func deviceCodeToken(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > deviceCodePrefix.count, trimmed.hasPrefix(deviceCodePrefix) else {
            return nil
        }
        return trimmed
    }

    private static func keychainResult(_ outcome: ClaudeKeychainReadOutcome<Data>) -> Result {
        switch outcome {
        case let .value(data):
            return tokenInKeychainPayload(data)
        case .notFound:
            return .needsConnect
        case .interactionRequired:
            return .needsKeychainAccess
        case .denied:
            return .needsConnect
        case .failure:
            return .unreadable
        }
    }

    /// The secret is JSON. Only `access_token` is read; `api_key` is never used,
    /// even when that field itself starts with `dca:`. A missing or blank
    /// access token still needs Connect.
    private static func tokenInKeychainPayload(_ data: Data) -> Result {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unreadable
        }
        guard let raw = root["access_token"] else { return .needsConnect }
        if raw is NSNull { return .needsConnect }
        if let text = raw as? String, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .needsConnect
        }
        guard let token = deviceCodeToken(raw) else { return .rejectedToken }
        return .token(token)
    }

    private static func jsonBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }
}
