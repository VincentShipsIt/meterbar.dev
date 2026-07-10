import Foundation
import os

/// Durable record of handled block fingerprints so a resumed session is never
/// rediscovered and resumed again after the app relaunches.
///
/// Backed by a single JSON file written atomically with `0600` permissions.
/// An unreadable or corrupt ledger fails safe to *empty* (nothing handled yet)
/// rather than throwing — a lost ledger should at worst allow one redundant
/// resume, never crash discovery.
actor ReplayLedger {
    private let fileURL: URL
    private var handled: Set<String>
    private var loaded = false

    /// - Parameter fileURL: ledger location; defaults to the private base dir.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? WakePaths.defaultBaseDirectory().appendingPathComponent("replay-ledger.json")
        self.handled = []
    }

    /// Whether this block was already handled in a previous or current run.
    func contains(_ fingerprint: BlockFingerprint) -> Bool {
        loadIfNeeded()
        return handled.contains(fingerprint.value)
    }

    /// Mark a block fingerprint as handled and persist immediately.
    func record(_ fingerprint: BlockFingerprint) {
        loadIfNeeded()
        guard handled.insert(fingerprint.value).inserted else { return }
        persist()
    }

    /// Test/diagnostic accessor for the current handled count.
    func count() -> Int {
        loadIfNeeded()
        return handled.count
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([String].self, from: data) else {
            handled = []
            return
        }
        handled = Set(stored)
    }

    private func persist() {
        do {
            try WakePaths.ensurePrivateDirectory(fileURL.deletingLastPathComponent())
            let data = try JSONEncoder().encode(handled.sorted())
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            AppLog.wake.error("Failed to persist replay ledger: \(error.localizedDescription, privacy: .public)")
        }
    }
}
