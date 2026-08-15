import Darwin
import Foundation

// MARK: - SecureFileWriter

/// Single owner of MeterBar's on-disk permission policy.
///
/// `Data.write(to:options: .atomic)` stages the payload in a scratch file
/// created at the process umask — 0644 for a default macOS session — and then
/// renames it into place. The conventional follow-up `chmod` therefore always
/// runs *after* the complete contents are already published at the loose mode,
/// and any local process can open the file inside that window and keep its
/// descriptor long after the mode is tightened.
///
/// This writer closes the window: the scratch file is created with `O_EXCL`
/// and the final mode is forced onto the descriptor with `fchmod` before a
/// single byte is written, so the payload is never reachable by another user
/// at any instant. The `rename` that publishes it stays atomic.
nonisolated enum SecureFileWriter {
    /// Owner read/write. The default for every cache, ledger, and snapshot the
    /// app persists.
    static let privateFile: mode_t = 0o600

    /// Owner read/write/execute, for files handed to an interpreter.
    static let privateExecutable: mode_t = 0o700

    /// Owner-only directory. Matches `WakePaths`, which predates this type.
    static let privateDirectory = 0o700

    // MARK: Directories

    /// Creates `directory` owner-only, or tightens it if it already exists.
    ///
    /// Tightening matters as much as creating: a directory left at 0755 by an
    /// earlier build stays 0755 forever otherwise.
    @discardableResult
    static func ensurePrivateDirectory(_ directory: URL) throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path) {
            // Only chmod a directory that actually needs it. `chmod(2)` can be
            // refused on a directory that already satisfies the policy —
            // `$TMPDIR` is owned by the user and already 0700 but carries the
            // `sunlnk` system flag, so an unconditional tighten returned EPERM
            // and every caller reported failure for a directory that was
            // private to begin with. Reading the mode first keeps the tighten
            // guarantee intact: anything looser still gets chmod'd, and a
            // genuine refusal there still propagates.
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            let current = (attributes[.posixPermissions] as? NSNumber)?.intValue
            if current != privateDirectory {
                try fileManager.setAttributes(
                    [.posixPermissions: privateDirectory],
                    ofItemAtPath: directory.path
                )
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: privateDirectory]
            )
        }
        return directory
    }

    // MARK: Files

    /// Makes `fileURL` exist and be owner-only without disturbing its contents.
    ///
    /// For append-only files — logs — where a whole-file replace is the wrong
    /// shape. Best-effort: a log line is never worth failing the work that
    /// produced it.
    static func ensurePrivateFile(at fileURL: URL) {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.setAttributes(
                [.posixPermissions: Int(privateFile)],
                ofItemAtPath: fileURL.path
            )
        } else {
            fileManager.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: Int(privateFile)]
            )
        }
    }

    static func write(
        _ string: String,
        to fileURL: URL,
        permissions: mode_t = privateFile
    ) throws {
        try write(Data(string.utf8), to: fileURL, permissions: permissions)
    }

    /// Atomically replaces `fileURL` with `data`, never exposing it at a mode
    /// looser than `permissions`.
    ///
    /// The parent directory must already exist; callers that own their
    /// directory should route it through ``ensurePrivateDirectory(_:)`` first.
    static func write(
        _ data: Data,
        to fileURL: URL,
        permissions: mode_t = privateFile
    ) throws {
        let stagingURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).partial")

        let descriptor = try createStagingFile(at: stagingURL, permissions: permissions)
        var isOpen = true
        var isPublished = false
        defer {
            if isOpen { close(descriptor) }
            // A failure anywhere below must not leave a half-written file
            // sitting next to the real one. `rename` consumes the staging path
            // on the success path, so there is nothing to unlink there.
            if !isPublished { try? FileManager.default.removeItem(at: stagingURL) }
        }

        // `open` masks the requested mode through the umask, so the descriptor
        // is not guaranteed to carry it yet. `fchmod` acts on the descriptor
        // rather than the path, which keeps this immune to the same swap the
        // whole type exists to prevent.
        guard fchmod(descriptor, permissions) == 0 else {
            throw SecureFileWriterError.write(code: errno, path: stagingURL.path)
        }

        try writeAll(data, to: descriptor, path: stagingURL.path)

        isOpen = false
        guard close(descriptor) == 0 else {
            throw SecureFileWriterError.write(code: errno, path: stagingURL.path)
        }

        guard rename(stagingURL.path, fileURL.path) == 0 else {
            throw SecureFileWriterError.replace(code: errno, path: fileURL.path)
        }
        isPublished = true
    }

    // MARK: Private

    private static func createStagingFile(at url: URL, permissions: mode_t) throws -> Int32 {
        while true {
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
            if descriptor >= 0 { return descriptor }
            if errno == EINTR { continue }
            throw SecureFileWriterError.create(code: errno, path: url.path)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        guard !data.isEmpty else { return }

        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                // A single `write` is not obliged to consume the whole buffer,
                // and a signal can cut it short with nothing written at all.
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SecureFileWriterError.write(code: errno, path: path)
                }
                offset += written
            }
        }
    }
}

// MARK: - SecureFileWriterError

enum SecureFileWriterError: LocalizedError {
    case create(code: Int32, path: String)
    case write(code: Int32, path: String)
    case replace(code: Int32, path: String)

    var errorDescription: String? {
        switch self {
        case let .create(code, path):
            "Could not create \(path): \(Self.describe(code))"
        case let .write(code, path):
            "Could not write \(path): \(Self.describe(code))"
        case let .replace(code, path):
            "Could not replace \(path): \(Self.describe(code))"
        }
    }

    /// Path-free rendering, for callers that log at `privacy: .public`.
    ///
    /// `errorDescription` names the file, which is right in front of a human
    /// holding the URL. Everything this writer touches lives under the user's
    /// home directory, though, so a log line built from it publishes the account
    /// name to the system log. The errno is the part an operator acts on —
    /// `ENOSPC` and `EACCES` call for different fixes — and it carries no path.
    var logDescription: String {
        switch self {
        case let .create(code, _):
            "create failed: \(Self.describe(code))"
        case let .write(code, _):
            "write failed: \(Self.describe(code))"
        case let .replace(code, _):
            "replace failed: \(Self.describe(code))"
        }
    }

    /// Path-free rendering of *any* error raised while persisting a file.
    ///
    /// The single entry point for the catch blocks that log at
    /// `privacy: .public`: they hold an opaque `Error`, so the narrowing has to
    /// happen here rather than at each call site — reaching for
    /// `localizedDescription` there is exactly the leak this exists to prevent.
    /// A writer error reduces to its errno; anything else — a Cocoa write error
    /// naming the file it could not save, an `EncodingError` naming the
    /// transcript path a cache is keyed by — reduces to a domain and code, which
    /// names nobody.
    static func logDescription(for error: Error) -> String {
        if let error = error as? SecureFileWriterError {
            return error.logDescription
        }
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    private static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
