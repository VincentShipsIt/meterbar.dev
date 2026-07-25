import Foundation
import os

/// Durable record of handled block fingerprints so a resumed session is never
/// rediscovered and resumed again after the app relaunches.
///
/// Backed by a single JSON file written atomically with `0600` permissions.
/// An unreadable or corrupt ledger fails safe to *empty* (nothing handled yet)
/// rather than throwing — a lost ledger should at worst allow one redundant
/// resume, never crash discovery.
///
/// Capacity is bounded: entries are kept in recording order (oldest first) and
/// pruned oldest-first beyond `maxEntries`, so the ledger can never grow
/// without limit. A pruned fingerprint could at worst be rediscovered, but a
/// months-old block is already excluded by discovery's transcript-age bound.
actor ReplayLedger {
    private let fileURL: URL
    private let maxEntries: Int
    /// Recording order, oldest first — the pruning order.
    private var order: [String]
    /// Same values as `order`, for O(1) membership checks.
    private var handled: Set<String>
    private var loaded = false

    /// - Parameters:
    ///   - fileURL: ledger location; defaults to the private base dir.
    ///   - maxEntries: capacity bound; oldest entries beyond it are pruned.
    init(fileURL: URL? = nil, maxEntries: Int = 500) {
        self.fileURL = fileURL
            ?? WakePaths.defaultBaseDirectory().appendingPathComponent("replay-ledger.json")
        self.maxEntries = max(1, maxEntries)
        self.order = []
        self.handled = []
    }

    /// Whether this block was already handled in a previous or current run.
    func contains(_ fingerprint: BlockFingerprint) -> Bool {
        loadIfNeeded()
        return handled.contains(fingerprint.value)
    }

    /// Mark a block fingerprint as handled, prune to capacity, and persist.
    func record(_ fingerprint: BlockFingerprint) {
        loadIfNeeded()
        guard handled.insert(fingerprint.value).inserted else { return }
        order.append(fingerprint.value)
        if order.count > maxEntries {
            let overflow = order.count - maxEntries
            for stale in order.prefix(overflow) {
                handled.remove(stale)
            }
            order.removeFirst(overflow)
        }
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
            order = []
            handled = []
            return
        }
        // Preserve on-disk order (oldest first) and drop duplicates so a
        // hand-edited or legacy file cannot inflate the count.
        order = []
        handled = []
        order.reserveCapacity(min(stored.count, maxEntries))
        for value in stored where handled.insert(value).inserted {
            order.append(value)
        }
        if order.count > maxEntries {
            let overflow = order.count - maxEntries
            for stale in order.prefix(overflow) {
                handled.remove(stale)
            }
            order.removeFirst(overflow)
        }
    }

    private func persist() {
        do {
            try WakePaths.ensurePrivateDirectory(fileURL.deletingLastPathComponent())
            // Persist in recording order (oldest first): the on-disk order *is*
            // the pruning order across relaunches.
            let data = try JSONEncoder().encode(order)
            try SecureFileWriter.write(data, to: fileURL)
        } catch {
            AppLog.wake.error("Failed to persist replay ledger: \(error.localizedDescription, privacy: .public)")
        }
    }
}
