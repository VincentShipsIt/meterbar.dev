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
    /// Guards `fileDescriptor`: the class is `@unchecked Sendable` and its
    /// descriptor may be touched from `acquire()`, `release()`, and `deinit` on
    /// different threads, so every read/write of it goes through this lock.
    private let stateLock = NSLock()
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

        // The whole open/flock/store sequence runs under `stateLock` so a
        // concurrent `release()` can't slip between a successful `flock` and
        // the descriptor store (which would leak the held lock), and a second
        // `acquire()` can't overwrite an already-held descriptor. `LOCK_NB`
        // keeps the critical section non-blocking.
        let acquired: Bool = stateLock.withLock {
            guard fileDescriptor < 0 else { return true }
            let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0 else { return false }
            if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                close(descriptor)
                return false
            }
            fileDescriptor = descriptor
            return true
        }
        return acquired ? .acquired : .contended
    }

    /// Release the lock and remove the descriptor. Safe to call repeatedly.
    func release() {
        stateLock.withLock {
            guard fileDescriptor >= 0 else { return }
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
            fileDescriptor = -1
        }
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
