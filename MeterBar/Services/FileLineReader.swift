import Foundation

/// Streams a newline-delimited file one line at a time.
///
/// The cost scanners used to read each transcript with `Data(contentsOf:)` and
/// then `String(data:encoding:)` before splitting — two full copies of every
/// `.jsonl` in `~/.claude/projects` and `~/.codex/archived_sessions` resident at
/// once. This reads a bounded buffer instead, so peak memory is the chunk size
/// plus the longest single line rather than the size of the largest transcript.
///
/// It is also more forgiving: one malformed byte no longer fails the whole-file
/// UTF-8 decode and silently zeroes an entire session's usage. Only the affected
/// line fails to parse.
nonisolated enum FileLineReader {
    /// 256 KiB — large enough that a multi-megabyte transcript costs few reads,
    /// small enough that many concurrent scans stay bounded.
    static let defaultChunkSize = 256 * 1024

    /// Invokes `body` once per line, without the trailing newline.
    ///
    /// `body` is a non-escaping function parameter on purpose: the Codex scan
    /// threads an `inout` accumulator through it, and capturing an `inout`
    /// parameter is only legal in a non-escaping closure.
    ///
    /// - Returns: `false` when the file could not be opened, `true` otherwise.
    ///   An empty file opens successfully and yields nothing.
    @discardableResult
    static func forEachLine(
        in url: URL,
        chunkSize: Int = defaultChunkSize,
        _ body: (Data) -> Void
    ) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let newline = UInt8(ascii: "\n")
        // Guards against a caller passing 0 and spinning forever on empty reads.
        let size = max(1, chunkSize)
        var pending = Data()

        while let chunk = try? handle.read(upToCount: size), !chunk.isEmpty {
            pending.append(chunk)
            var searchStart = pending.startIndex

            while let newlineIndex = pending[searchStart...].firstIndex(of: newline) {
                body(Self.line(pending[searchStart..<newlineIndex]))
                searchStart = pending.index(after: newlineIndex)
            }

            if searchStart > pending.startIndex {
                // Re-base rather than `removeSubrange` so the next slice search
                // starts from index 0 again.
                pending = Data(pending[searchStart...])
            }
        }

        if !pending.isEmpty {
            body(Self.line(pending[...]))
        }
        return true
    }

    /// Copies the slice into a zero-based `Data` and drops a CRLF carriage
    /// return. The copy matters: slicing `Data` keeps the parent's non-zero
    /// `startIndex`, and `JSONSerialization` has historically mis-read offset
    /// slices.
    private static func line(_ slice: Data) -> Data {
        if slice.last == UInt8(ascii: "\r") {
            return Data(slice.dropLast())
        }
        return Data(slice)
    }
}
