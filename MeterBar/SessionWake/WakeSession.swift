import CryptoKit
import Foundation

/// A deterministic identity for a single blocking event, used to guarantee a
/// handled block is never resumed twice (even across app relaunch).
///
/// It intentionally keys on the *event* (session + block instant + reason), not
/// the file, so re-scanning the same transcript yields the same fingerprint,
/// while a genuinely new block later in the same session produces a new one.
struct BlockFingerprint: Codable, Equatable, Hashable, Sendable {
    let value: String

    init(sessionID: String, blockedAt: Date, reason: WakeBlockReason) {
        // Second precision: the same event re-read must hash identically.
        let epochSecond = Int(blockedAt.timeIntervalSince1970.rounded())
        let seed = "\(sessionID)|\(epochSecond)|\(reason.rawValue)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        self.value = digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Why a discovered candidate cannot be executed as-is.
enum WakeSkipReason: String, Codable, Equatable, Sendable {
    /// The transcript's resolved cwd no longer exists (deleted worktree).
    case missingWorkingDirectory
    /// The transcript never recorded a working directory.
    case unknownWorkingDirectory
    /// This block fingerprint was already handled (replay ledger hit).
    case alreadyHandled
    /// The transcript belongs to a subagent/sidechain.
    case subagent
}

/// A blocked Claude Code session that Session Wake could resume.
///
/// `skipReason == nil` means the candidate is executable; a non-nil reason
/// means it is preview-only and must never be launched. Discovery records the
/// reason rather than silently dropping the candidate so the UI/CLI can explain
/// why a visible blocked session was not resumed.
struct WakeSessionCandidate: Equatable, Sendable, Identifiable {
    let sessionID: String
    let transcriptPath: String
    /// Canonicalized (symlinks resolved) working directory, if resolvable.
    let workingDirectory: String?
    let gitBranch: String?
    let reason: WakeBlockReason
    let blockedAt: Date
    /// Absolute reset instant parsed from the transcript, anchored to the event.
    let resetHint: TranscriptResetParser.Result?
    let fingerprint: BlockFingerprint
    let skipReason: WakeSkipReason?

    var id: String { fingerprint.value }

    /// True only when the candidate is safe to hand to the runner.
    var isExecutable: Bool { skipReason == nil }
}
