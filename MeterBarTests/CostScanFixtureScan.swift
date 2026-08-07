import Foundation
@testable import MeterBar

/// Drives a whole fixture directory of Codex rollouts into a scan window.
///
/// The production budgeted scan reaches rollouts through `CostScanCorpus`
/// (newest-modified first) and a per-file byte cache. Fixtures that assert on
/// cross-file dedup order, truncated lines, or attribution resets want neither:
/// they want one fixed, readable order and a plain end-to-end read of each file.
/// So this walks the tree in sorted-path order — `FileManager` yields directory
/// entries in whatever order the volume hands back, and Codex dedup is
/// first-event-wins — and hands each file to the scanner one at a time.
enum CostScanFixtureScan {
    static func codexRollouts(in directory: URL, windows: inout ScanWindows<CostScanWindowContext>) {
        for url in Self.transcripts(in: directory) {
            CodexCostScanner.parseRollout(at: url, windows: &windows)
        }
    }

    /// Single-window variant for fixtures that only assert on one period: scans
    /// into `context` as the period window and discards lifetime.
    static func codexRollouts(
        in directory: URL,
        since cutoffDate: Date,
        context: inout CostScanWindowContext
    ) {
        var windows = ScanWindows(
            period: context,
            lifetime: CostScanWindowContext(earliestDate: Date(), latestDate: .distantPast),
            cutoff: cutoffDate
        )
        Self.codexRollouts(in: directory, windows: &windows)
        context = windows.period
    }

    private static func transcripts(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }
}
