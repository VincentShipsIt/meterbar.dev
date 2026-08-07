import Foundation
import os

/// Counts the lines a scan could not retain whole, and how many of them still
/// yielded usage.
///
/// A truncated line that salvage cannot decode is a record whose tokens are
/// missing from the totals. Nothing in the pipeline surfaced that before: the
/// reader flagged the line, the scanner dropped it through a `try?`, and the
/// number the menu bar showed was quietly short. One line per affected file is
/// enough to make that visible without turning a 10 GB corpus into a log flood.
///
/// Only counts and the file's path are ever logged — never a byte of the line.
nonisolated struct CostScanTruncationTally {
    private(set) var truncated = 0
    private(set) var recovered = 0

    var unrecovered: Int { truncated - recovered }
    var isEmpty: Bool { truncated == 0 }

    mutating func note(_ line: FileLineReader.Line, recovered: Bool) {
        guard line.wasTruncated else { return }
        truncated += 1
        if recovered { self.recovered += 1 }
    }

    /// Emits at most one line per file. Silent when the file had no truncation,
    /// which is the overwhelming majority of them.
    func log(url: URL) {
        guard !isEmpty else { return }
        if unrecovered == 0 {
            AppLog.cost.notice(
                """
                Recovered usage from \(recovered, privacy: .public) oversized line(s) \
                in \(url.path, privacy: .private)
                """
            )
        } else {
            AppLog.cost.warning(
                """
                Dropped \(unrecovered, privacy: .public) of \(truncated, privacy: .public) oversized line(s), \
                recovered \(recovered, privacy: .public), in \(url.path, privacy: .private)
                """
            )
        }
    }
}
