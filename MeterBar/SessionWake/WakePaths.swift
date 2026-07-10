import Foundation

/// Central resolver for Session Wake's private on-disk state.
///
/// Everything lives under one base directory created with `0700` so ledger and
/// (later) log files inherit private permissions. The base is overridable so
/// tests never touch the real Application Support tree.
enum WakePaths {
    /// Default base: `~/Library/Application Support/MeterBar/session-wake`.
    static func defaultBaseDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "\(ServiceSupport.realHomeDirectory())/Library/Application Support")
        return support
            .appendingPathComponent("MeterBar", isDirectory: true)
            .appendingPathComponent("session-wake", isDirectory: true)
    }

    /// Ensure `directory` exists with private (`0700`) permissions.
    @discardableResult
    static func ensurePrivateDirectory(_ directory: URL) throws -> URL {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        return directory
    }
}
