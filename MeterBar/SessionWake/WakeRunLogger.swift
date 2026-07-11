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
            AppLog.wake.error("Failed to write wake log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func appendData(_ data: Data, to fileURL: URL) {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        } else {
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
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
