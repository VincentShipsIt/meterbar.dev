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
        // How much of `pending` has already been searched and proven to hold no
        // newline. Every byte left in `pending` at the end of an iteration is
        // part of an unterminated line, so the next chunk resumes from here
        // instead of rescanning from byte 0. Without it a line spanning N
        // chunks costs N rescans of a buffer that grows to the line's full
        // length — O(L^2 / chunkSize). Real Codex rollout transcripts carry
        // single lines in the tens of megabytes, which turned a one-second scan
        // into over a minute.
        var scanned = 0

        while let chunk = try? handle.read(upToCount: size), !chunk.isEmpty {
            pending.append(chunk)

            // `lineStart` and `searchFrom` are distinct: the line still begins
            // at the front of the buffer even when the search resumes deeper
            // in. Conflating them would emit an empty line and drop the real
            // one whenever a newline landed on the first byte of a chunk.
            var lineStart = pending.startIndex
            var searchFrom = pending.index(pending.startIndex, offsetBy: scanned)

            while let newlineIndex = pending[searchFrom...].firstIndex(of: newline) {
                body(Self.line(pending[lineStart..<newlineIndex]))
                lineStart = pending.index(after: newlineIndex)
                searchFrom = lineStart
            }

            if lineStart > pending.startIndex {
                // Re-base rather than `removeSubrange` so the next slice search
                // starts from index 0 again.
                pending = Data(pending[lineStart...])
            }
            scanned = pending.count
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
