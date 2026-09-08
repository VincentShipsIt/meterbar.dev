import Darwin
import Foundation
import os

/// Structured, privacy-preserving log of wake runs.
///
/// Default logs contain metadata only — session id, typed reason, outcome, exit
/// code, duration, byte counts. They deliberately never contain the prompt, the
/// transcript, tool output, credentials, or any raw stdout/stderr tail. The log
/// directory is `0700` and every file `0600`, with day-based rotation and a
/// bounded retention window.
nonisolated struct WakeRunLogger: Sendable {
    /// One structured record. No free-form content fields exist by design.
    struct Record: Codable, Equatable, Sendable {
        let timestamp: Date
        let event: String
        let sessionID: String
        let reason: String
        let outcome: String
        let exitCode: Int32?
        let durationMilliseconds: Int?
        let stdoutBytes: Int?
        let stderrBytes: Int?
    }

    private let directory: URL
    private let retentionDays: Int
    private let now: @Sendable () -> Date

    init(
        directory: URL? = nil,
        retentionDays: Int = 14,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory ?? WakePaths.defaultBaseDirectory().appendingPathComponent("logs", isDirectory: true)
        self.retentionDays = retentionDays
        self.now = now
    }

    /// Append `record` to today's log, creating private files as needed and
    /// pruning logs older than the retention window.
    func append(_ record: Record) {
        do {
            try WakePaths.ensurePrivateDirectory(directory)
            let fileURL = directory.appendingPathComponent("session-wake-\(dayStamp(record.timestamp)).log")
            var line = try JSONEncoder.wakeEncoder.encode(record)
            line.append(0x0A) // newline
            appendData(line, to: fileURL)
            pruneOldLogs()
        } catch {
            AppLog.wake.error(
                "Failed to write wake log: \(SecureFileWriterError.logDescription(for: error), privacy: .public)"
            )
        }
    }

    /// Appends `data` atomically with respect to every other writer to the
    /// same file — same-process (`WakeProcessRunner.record` and
    /// `WakeEventHookRunner.record` both fire from the same state transition)
    /// and cross-process alike.
    ///
    /// `WakeRunLogger` is a `struct`: every caller holds an independent value
    /// with no shared in-process state, so an `NSLock` on `self` would not
    /// help here — the actual writers are separate `WakeRunLogger` instances,
    /// sometimes in separate processes. `flock(LOCK_EX)` (blocking, not the
    /// `LOCK_NB` `WakeLock` uses — a logger write must wait its turn, not fail)
    /// around an `O_APPEND` write is the same primitive `WakeLock` already
    /// uses for cross-process mutual exclusion, applied here as a plain
    /// critical section rather than a held lock. `O_APPEND` alone (as before)
    /// is not enough: two writers can each open the file, both seek to the
    /// current end, and interleave their `write(2)` calls, tearing a line in
    /// half. Holding the flock across open→write→close closes that window.
    ///
    /// Deliberately does not call `SecureFileWriter.ensurePrivateFile` as a
    /// separate step before opening the file: that would add a second
    /// open/close/`fchmod` round trip that buys nothing here, since this
    /// method has to open the file itself anyway to hold the `flock` across
    /// the write. So private-mode enforcement is done in one open, on the
    /// same already-open descriptor via `fchmod` — the same "act on the
    /// descriptor, not the path" technique `SecureFileWriter.write` itself
    /// uses, and `ensurePrivateFile` now also uses internally.
    ///
    /// (Historical note: this split from `ensurePrivateFile` originally
    /// because that helper's "does it exist? then `createFile`" check was
    /// itself racy — `createFile(atPath:contents:nil,…)` unconditionally
    /// (re)created an empty file, so two writers whose existence checks both
    /// landed before either's `createFile` ran could truncate a file a third
    /// writer had already appended to. `ensurePrivateFile` is fixed now — see
    /// `SecureFileWriter.ensurePrivateFile` — but this method still has no
    /// reason to call it separately.)
    private func appendData(_ data: Data, to fileURL: URL) {
        let descriptor = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = fchmod(descriptor, SecureFileWriter.privateFile)
        guard flock(descriptor, LOCK_EX) == 0 else { return }
        defer { flock(descriptor, LOCK_UN) }

        data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let n = write(descriptor, base + written, rawBuffer.count - written)
                if n > 0 {
                    written += n
                } else if n == -1, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private func pruneOldLogs() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)
        for url in entries where url.pathExtension == "log" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

nonisolated private extension JSONEncoder {
    static let wakeEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
