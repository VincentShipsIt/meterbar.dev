import Foundation

/// What a refresh is about to read — or is already reading — so the Costs page
/// can say "42 files, 180 MB, last 30 days" instead of a silent hang.
///
/// Listed counts come from the mtime-filtered walk, not the whole home
/// directory. A 10 GB archive that has not been touched inside the window does
/// not appear here.
nonisolated struct CostScanProgress: Equatable, Sendable {
    var windowDays: Int
    var listedFiles: Int
    var listedBytes: Int64
    var processedFiles: Int
    var bytesRead: Int
    var isComplete: Bool
    /// `.zst` Codex rollouts found inside the window with no readable copy
    /// anywhere in the corpus (issue #570) — Codex's `codex.rollout_compression`
    /// job archives a rollout by deleting the `.jsonl` source MeterBar's
    /// scanners read. Defaults to 0 so every existing call site still compiles
    /// unchanged; a scan that never looked for the gap reports none, not one
    /// it ruled out.
    var codexCompressedRolloutCount: Int

    /// 1 GiB. Above this the banner warns that even the windowed corpus is huge.
    static let largeCorpusBytes: Int64 = 1_073_741_824

    init(
        windowDays: Int,
        listedFiles: Int = 0,
        listedBytes: Int64 = 0,
        processedFiles: Int = 0,
        bytesRead: Int = 0,
        isComplete: Bool = false,
        codexCompressedRolloutCount: Int = 0
    ) {
        self.windowDays = windowDays
        self.listedFiles = listedFiles
        self.listedBytes = listedBytes
        self.processedFiles = processedFiles
        self.bytesRead = bytesRead
        self.isComplete = isComplete
        self.codexCompressedRolloutCount = codexCompressedRolloutCount
    }

    var isLargeCorpus: Bool { listedBytes >= Self.largeCorpusBytes }

    /// A short total is a silent under-count without this — see
    /// `CodexCostScanner.compressedRolloutGap`.
    var hasCodexCompressedRolloutGap: Bool { codexCompressedRolloutCount > 0 }

    var fraction: Double? {
        guard listedFiles > 0 else { return nil }
        if isComplete { return 1 }
        // Deferred or still-open files can make processedFiles catch listedFiles
        // before the refresh is done. Never report 100% in that state.
        return min(
            Double(processedFiles) / Double(listedFiles),
            Double(listedFiles - 1) / Double(listedFiles)
        )
    }

    var formattedListedSize: String { Self.formatBytes(listedBytes) }

    var statusText: String {
        if listedFiles == 0 && !isComplete {
            return "Listing session files…"
        }
        if isComplete {
            return "Scanned \(listedFiles) files (\(formattedListedSize))"
        }
        if processedFiles > 0 {
            return "Scanning \(processedFiles) of \(listedFiles) files · \(formattedListedSize)"
        }
        return "Scanning \(listedFiles) files (\(formattedListedSize))"
    }

    var detailText: String {
        if hasCodexCompressedRolloutGap {
            let plural = codexCompressedRolloutCount == 1 ? "rollout" : "rollouts"
            return "\(codexCompressedRolloutCount) compressed Codex \(plural) in this window " +
                "aren't counted — MeterBar reads .jsonl logs only."
        }
        if isLargeCorpus {
            return "This \(windowDays)-day window is still \(formattedListedSize). Older archives are not scanned."
        }
        return "Only files touched in the last \(windowDays) days. Quota APIs do not include this history."
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
