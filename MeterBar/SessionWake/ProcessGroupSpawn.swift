import Darwin
import Foundation

/// Starts a child process as the leader of its own process group, with a clean
/// signal state, for every place MeterBar spawns a CLI it may later stop.
///
/// The callers own their pipes and `fileActions`; this owns the parts that must
/// not drift between them.
nonisolated enum ProcessGroupSpawn {
    /// `posix_spawn`'s result code and the child's pid (also its pgid). A
    /// non-zero `status` means nothing was spawned.
    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        fileActions: inout posix_spawn_file_actions_t?
    ) -> (pid: pid_t, status: Int32) {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // We spawn from libdispatch worker threads, whose signal mask may block
        // SIGTERM. A child inheriting that mask could only be stopped by the
        // unblockable SIGKILL, so empty the mask and restore every disposition
        // to SIG_DFL.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        // New process group with the child as leader ⇒ kill(-pgid) hits the tree.
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        )

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &fileActions, &attributes, argv, envp)
        return (pid, status)
    }
}
