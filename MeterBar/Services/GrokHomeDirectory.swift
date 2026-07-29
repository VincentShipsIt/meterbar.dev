import Foundation

/// Resolves the official Grok Build state directory without inspecting any
/// credential bytes. Grok Build honors `GROK_HOME` and defaults to `~/.grok`.
nonisolated enum GrokHomeDirectory {
    static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> String {
        guard let rawValue = environment["GROK_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty else {
            return (realHomeDirectory as NSString).appendingPathComponent(".grok")
        }
        return expand(rawValue, realHomeDirectory: realHomeDirectory)
    }

    static func authFilePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> String {
        (path(environment: environment, realHomeDirectory: realHomeDirectory) as NSString)
            .appendingPathComponent("auth.json")
    }

    static func path(for account: GrokAccount) -> String {
        guard let homeDirectory = account.homeDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !homeDirectory.isEmpty else {
            return path()
        }
        return expand(homeDirectory)
    }

    static func authFilePath(for account: GrokAccount) -> String {
        (path(for: account) as NSString).appendingPathComponent("auth.json")
    }

    static func expand(
        _ rawValue: String,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> String {
        if rawValue == "~" {
            return realHomeDirectory
        }
        if rawValue.hasPrefix("~/") {
            return (realHomeDirectory as NSString).appendingPathComponent(String(rawValue.dropFirst(2)))
        }
        return (rawValue as NSString).standardizingPath
    }
}
