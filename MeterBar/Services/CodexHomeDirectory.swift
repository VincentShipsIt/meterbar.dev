import Foundation

/// Resolves the Codex state directory consistently for every local integration.
///
/// Codex honors `CODEX_HOME`; MeterBar must therefore use the same directory for
/// activity, auth, readiness, and cost scans. Keeping this path logic pure also
/// lets tests exercise custom homes without mutating the process environment.
nonisolated enum CodexHomeDirectory {
    static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> String {
        guard let rawValue = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty else {
            return (realHomeDirectory as NSString).appendingPathComponent(".codex")
        }

        if rawValue == "~" {
            return realHomeDirectory
        }
        if rawValue.hasPrefix("~/") {
            return (realHomeDirectory as NSString).appendingPathComponent(String(rawValue.dropFirst(2)))
        }
        return (rawValue as NSString).standardizingPath
    }

    static func authFilePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> String {
        (path(environment: environment, realHomeDirectory: realHomeDirectory) as NSString)
            .appendingPathComponent("auth.json")
    }

    static func path(for account: CodexAccount) -> String {
        guard let homeDirectory = account.homeDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines), !homeDirectory.isEmpty else {
            return path()
        }
        return (homeDirectory as NSString).standardizingPath
    }

    static func authFilePath(for account: CodexAccount) -> String {
        (path(for: account) as NSString).appendingPathComponent("auth.json")
    }

    /// The resolved auth-file path for user-facing copy, compacting paths under
    /// the real home directory back to `~/...` while retaining absolute custom
    /// `CODEX_HOME` paths outside it.
    static func authFileDisplayPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> String {
        let resolvedPath = (authFilePath(
            environment: environment,
            realHomeDirectory: realHomeDirectory
        ) as NSString).standardizingPath
        let standardizedHome = (realHomeDirectory as NSString).standardizingPath
        let homePrefix = standardizedHome.hasSuffix("/") ? standardizedHome : "\(standardizedHome)/"

        guard resolvedPath.hasPrefix(homePrefix) else {
            return resolvedPath
        }
        return "~/\(resolvedPath.dropFirst(homePrefix.count))"
    }
}
