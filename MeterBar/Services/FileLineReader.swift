import Foundation

/// Where to start reading, and how much to read.
nonisolated struct FileLineReadRequest {
    /// Byte offset to seek to before reading. Comes from the previous refresh's
    /// `FileLineReadResult.committedOffset`, so a resumed read sees only bytes
    /// appended since.
    var startOffset: UInt64 = 0

    /// Ceiling on bytes pulled off disk in this call. The reader stops at the
    /// last complete line inside the ceiling; the rest of the file is left for
    /// the next refresh.
    var maxBytes: Int = .max

    var chunkSize: Int = FileLineReader.defaultChunkSize

    /// Yield the final line even when it has no trailing newline and is not
    /// structurally complete JSON.
    ///
    /// Only `forEachLine` sets this, to preserve its whole-file semantics. The
    /// resumable path must not: transcripts are appended to while being read, so
    /// a trailing fragment there is a record still being written.
    var commitsUnterminatedTrailingLine = false
}

/// Where the next read should pick up, and why this one stopped.
nonisolated struct FileLineReadResult {
    /// One past the last line handed to `body`. Safe to persist: every byte
    /// before it has been accounted for exactly once.
    var committedOffset: UInt64

    /// Bytes actually read from disk, which is what the refresh budget spends.
    /// Larger than `committedOffset - startOffset` whenever the read stopped
    /// mid-line.
    var bytesRead: Int

    /// `true` only when a read came back empty. `false` means the byte ceiling
    /// stopped the read with more file left.
    var reachedEndOfFile: Bool
}

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
        var request = FileLineReadRequest()
        request.chunkSize = chunkSize
        // Whole-file reads have no budget and no follow-up pass, so a trailing
        // fragment is all the caller will ever get — yield it.
        request.commitsUnterminatedTrailingLine = true
        return readLines(in: url, request: request) { line, _ in body(line) } != nil
    }

    /// Reads lines from `request.startOffset` up to `request.maxBytes`.
    ///
    /// `body` receives each line's payload and the byte offset the line *starts*
    /// at, which is what the Codex scan needs to roll its committed offset back
    /// to the first event it had to defer.
    ///
    /// - Returns: `nil` when the file could not be opened or sought.
    static func readLines(
        in url: URL,
        request: FileLineReadRequest,
        _ body: (Data, UInt64) -> Void
    ) -> FileLineReadResult? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        if request.startOffset > 0 {
            do {
                try handle.seek(toOffset: request.startOffset)
            } catch {
                return nil
            }
        }

        let newline = UInt8(ascii: "\n")
        // Guards against a caller passing 0 and spinning forever on empty reads.
        let chunkSize = max(1, request.chunkSize)
        let budget = max(0, request.maxBytes)
        var committed = request.startOffset
        var bytesRead = 0
        var reachedEnd = false
        var pending = Data()

        while bytesRead < budget {
            // `read(upToCount:)` signals end of file by returning `nil` *or* an
            // empty `Data` depending on the handle, and only a thrown error means
            // the read actually failed. Collapsing the two with `try?` would
            // report EOF as a failure, and the caller reads `reachedEndOfFile` to
            // decide whether a file is done — a false negative there re-reads
            // every transcript from its offset on every refresh, forever.
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: min(chunkSize, budget - bytesRead))
            } catch {
                break
            }
            guard let chunk, !chunk.isEmpty else {
                reachedEnd = true
                break
            }
            bytesRead += chunk.count
            pending.append(chunk)
            var searchStart = pending.startIndex

            while let newlineIndex = pending[searchStart...].firstIndex(of: newline) {
                let slice = pending[searchStart..<newlineIndex]
                body(Self.line(slice), committed)
                committed += UInt64(slice.count) + 1
                searchStart = pending.index(after: newlineIndex)
            }

            if searchStart > pending.startIndex {
                // Re-base rather than `removeSubrange` so the next slice search
                // starts from index 0 again.
                pending = Data(pending[searchStart...])
            }
        }

        // A residual left behind because the budget ran out is a line the file
        // continues past — never commit it, even when the bytes read so far
        // happen to look like complete JSON.
        let stoppedForBudget = !reachedEnd && bytesRead >= budget
        if !pending.isEmpty, !stoppedForBudget,
           request.commitsUnterminatedTrailingLine || isStructurallyCompleteJSONLine(pending) {
            body(Self.line(pending[...]), committed)
            committed += UInt64(pending.count)
        }

        return FileLineReadResult(
            committedOffset: committed,
            bytesRead: bytesRead,
            reachedEndOfFile: reachedEnd
        )
    }

    /// Cheap structural check for a trailing line with no newline yet.
    ///
    /// Claude Code and Codex append to transcripts while the scan reads them, so
    /// the last line is routinely half-written. Committing one would double-count
    /// the record once the rest lands, and re-reading from before it every
    /// refresh would give up the offsets entirely — so the reader commits a
    /// newline-less line only when its brackets balance outside of strings.
    ///
    /// This is not validation: `{"a":}` passes, and the parser rejects it
    /// harmlessly a moment later. It only has to catch a write that stopped
    /// mid-record, which always leaves an unclosed bracket or an open string.
    static func isStructurallyCompleteJSONLine(_ data: Data) -> Bool {
        var expected: [UInt8] = []
        var inString = false
        var escaped = false
        var sawContent = false

        for byte in data {
            if escaped {
                escaped = false
                continue
            }
            if inString {
                switch byte {
                case UInt8(ascii: "\\"): escaped = true
                case UInt8(ascii: "\""): inString = false
                default: break
                }
                continue
            }
            switch byte {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"), UInt8(ascii: "\n"):
                continue
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"):
                expected.append(UInt8(ascii: "}"))
            case UInt8(ascii: "["):
                expected.append(UInt8(ascii: "]"))
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                guard expected.popLast() == byte else { return false }
            default:
                break
            }
            sawContent = true
        }

        return sawContent && !inString && !escaped && expected.isEmpty
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
