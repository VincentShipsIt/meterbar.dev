import Darwin
import Foundation

/// The descriptor the current holder writes into the lock file so a contender
/// can report *who* holds it instead of a bare "contended".
nonisolated struct WakeLockHolder: Codable, Equatable, Sendable {
    /// Who is holding the shared lock.
    enum Kind: String, Codable, Equatable, Sendable {
        case app
        case cli
    }

    let kind: Kind
    let pid: Int32
    let host: String
    let startedAtEpoch: Double

    var startedAt: Date { Date(timeIntervalSince1970: startedAtEpoch) }

    /// A compact, log-safe label ("cli, pid 123 on host") for user-facing
    /// contention messages.
    var shortDescription: String {
        "\(kind.rawValue), pid \(pid) on \(host)"
    }
}

/// One advisory-lock protocol shared by MeterBar, `meterbar wake`, and the
/// legacy watcher during migration.
///
/// Uses `flock(LOCK_EX|LOCK_NB)` on a fixed lock file so any two holders — the
/// app and the CLI, or either and a still-loaded legacy job — mutually exclude.
/// The lock is acquired only when a run is actually ready, never held across a
/// long quota wait. The holder writes a JSON descriptor into the lock file so a
/// contender can say who is running.
nonisolated final class WakeLock: @unchecked Sendable {
    /// The outcome of trying to acquire the shared lock.
    enum Acquisition: Equatable {
        case acquired
        /// Held by another MeterBar/CLI holder; `holder` is present when its
        /// descriptor could be read from the lock file.
        case contended(holder: WakeLockHolder?)
        /// A known legacy watcher lock is present — actionable guidance.
        case legacyHeld(guidance: String)
        /// The lock file or its directory could not be created/opened at all —
        /// an environment failure, distinct from another holder being active.
        case unavailable(reason: String)
    }

    private let lockURL: URL
    private let legacyLockURLs: [URL]
    private let holderKind: WakeLockHolder.Kind
    /// Guards `fileDescriptor`: the class is `@unchecked Sendable` and its
    /// descriptor may be touched from `acquire()`, `release()`, and `deinit` on
    /// different threads, so every read/write of it goes through this lock.
    private let stateLock = NSLock()
    private var fileDescriptor: Int32 = -1

    /// Resolved once — `hostName` can trigger reverse-DNS and stall, which we
    /// never want inside `acquire()`'s critical section.
    private static let cachedHostName = ProcessInfo.processInfo.hostName

    init(lockURL: URL? = nil, legacyLockURLs: [URL]? = nil, holderKind: WakeLockHolder.Kind = .app) {
        self.lockURL = lockURL
            ?? WakePaths.defaultBaseDirectory().appendingPathComponent("wake.lock")
        self.holderKind = holderKind
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
            return .unavailable(reason: "lock directory: \(error.localizedDescription)")
        }

        // The whole open/flock/write-holder/store sequence runs under
        // `stateLock` so a concurrent `release()` can't slip between a
        // successful `flock` and the descriptor store (which would leak the
        // held lock), and a second `acquire()` can't overwrite an already-held
        // descriptor. `LOCK_NB` keeps the critical section non-blocking.
        return stateLock.withLock {
            guard fileDescriptor < 0 else { return .acquired }
            // O_CLOEXEC so the spawned `claude` child does not inherit the
            // held flock fd — otherwise a parent that dies mid-run leaves the
            // child holding the lock with a dead pid in the descriptor.
            let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else {
                return .unavailable(reason: "open lock: \(String(cString: strerror(errno)))")
            }
            if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let blocked = errno == EWOULDBLOCK
                close(descriptor)
                return blocked
                    ? .contended(holder: readHolder())
                    : .unavailable(reason: "flock: \(String(cString: strerror(errno)))")
            }
            writeHolder(to: descriptor)
            fileDescriptor = descriptor
            return .acquired
        }
    }

    /// Release the lock, clearing the holder descriptor so a later contender
    /// does not attribute the (now free) lock to us. Safe to call repeatedly.
    func release() {
        stateLock.withLock {
            guard fileDescriptor >= 0 else { return }
            ftruncate(fileDescriptor, 0)
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    // MARK: - Holder descriptor

    /// Read the current holder's descriptor without taking the lock. `nil` when
    /// the file is empty (released, or a holder that has not written yet) or
    /// does not decode.
    private func readHolder() -> WakeLockHolder? {
        guard let data = try? Data(contentsOf: lockURL), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(WakeLockHolder.self, from: data)
    }

    /// Write our descriptor into the freshly-locked file for contenders to read.
    /// Best-effort: a failed write degrades a contender's message, never the lock.
    private func writeHolder(to descriptor: Int32) {
        // hostName can stall on reverse-DNS; resolve it before we are called
        // (inside the stateLock critical section) — see cachedHostName.
        let holder = WakeLockHolder(
            kind: holderKind,
            pid: getpid(),
            host: WakeLock.cachedHostName,
            startedAtEpoch: Date().timeIntervalSince1970
        )
        guard let data = try? JSONEncoder().encode(holder) else { return }
        ftruncate(descriptor, 0)
        lseek(descriptor, 0, SEEK_SET)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = write(descriptor, base + written, raw.count - written)
                if count > 0 {
                    written += count
                } else if count == -1 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
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
