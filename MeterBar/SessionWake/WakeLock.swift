import Darwin
import Foundation

/// One advisory-lock protocol shared by MeterBar, `meterbar wake`, and the
/// legacy watcher during migration.
///
/// Uses `flock(LOCK_EX|LOCK_NB)` on a fixed lock file so any two holders — the
/// app and the CLI, or either and a still-loaded legacy job — mutually exclude.
/// The lock is acquired only when a run is actually ready, never held across a
/// long quota wait.
nonisolated final class WakeLock: @unchecked Sendable {
    /// The outcome of trying to acquire the shared lock.
    enum Acquisition: Equatable {
        case acquired
        /// Held by another MeterBar/CLI holder.
        case contended
        /// A known legacy watcher lock is present — actionable guidance.
        case legacyHeld(guidance: String)
    }

    private let lockURL: URL
    private let legacyLockURLs: [URL]
    private var fileDescriptor: Int32 = -1

    init(lockURL: URL? = nil, legacyLockURLs: [URL]? = nil) {
        self.lockURL = lockURL
            ?? WakePaths.defaultBaseDirectory().appendingPathComponent("wake.lock")
        // Conventional legacy watcher lock locations from the Python/launchd era.
        self.legacyLockURLs = legacyLockURLs ?? [
            URL(fileURLWithPath: "\(ServiceSupport.realHomeDirectory())/.claude/wake-watcher.lock"),
            URL(fileURLWithPath: "\(ServiceSupport.realHomeDirectory())/.meterbar/session-wake.lock")
        ]
    }

    /// Attempt to acquire the lock, reporting legacy contention distinctly so a
    /// user can be told to unload the old job rather than seeing a bare failure.
    func acquire() -> Acquisition {
        if let legacy = heldLegacyLock() {
            return .legacyHeld(guidance: """
            A legacy Session Wake watcher appears to be running (\(legacy.path)). \
            Unload it before enabling native Session Wake: `launchctl bootout` the \
            old job and delete its plist/scripts. See docs/session-wake-migration.md.
            """)
        }

        do {
            try WakePaths.ensurePrivateDirectory(lockURL.deletingLastPathComponent())
        } catch {
            return .contended
        }

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return .contended }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            return .contended
        }
        fileDescriptor = descriptor
        return .acquired
    }

    /// Release the lock and remove the descriptor. Safe to call repeatedly.
    func release() {
        guard fileDescriptor >= 0 else { return }
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
        fileDescriptor = -1
    }

    /// Whether any known legacy lock file is currently `flock`-held by another
    /// process (present-but-unlocked files are ignored — a stale file is not a
    /// running watcher).
    private func heldLegacyLock() -> URL? {
        for url in legacyLockURLs {
            let descriptor = open(url.path, O_RDWR)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                // We could take it ⇒ nobody holds it. Release immediately.
                flock(descriptor, LOCK_UN)
            } else {
                return url
            }
        }
        return nil
    }

    deinit { release() }
}
