import Foundation

/// Streams a newline-delimited file one line at a time.
///
/// The cost scanners used to read each transcript with `Data(contentsOf:)` and
/// then `String(data:encoding:)` before splitting — two full copies of every
/// `.jsonl` in `~/.claude/projects` and `~/.codex/archived_sessions` resident at
/// once. This reads a bounded buffer instead, so peak memory is the chunk size
/// plus at most `maxLineBytes` rather than the size of the largest transcript.
///
/// It is also more forgiving: one malformed byte no longer fails the whole-file
/// UTF-8 decode and silently zeroes an entire session's usage. Only the affected
/// line fails to parse.
nonisolated enum FileLineReader {
    /// 256 KiB — large enough that a multi-megabyte transcript costs few reads,
    /// small enough that many concurrent scans stay bounded.
    static let defaultChunkSize = 256 * 1024

    /// 1 MiB. Codex rollouts under `~/.codex/sessions` and
    /// `~/.codex/archived_sessions` contain single JSONL lines up to 56 MB, and
    /// holding one of those resident is the whole reason this cap exists. Bytes
    /// past it are counted but never buffered.
    static let defaultMaxLineBytes = 1024 * 1024

    /// 1 MiB — how much of an oversized line survives for the parser. Usage and
    /// token fields sit near the front of these records, so the retained prefix
    /// is often still parseable. Dropping the line outright would discard a real
    /// usage record and under-report spend, which is the failure this avoids.
    static let defaultPrefixBytes = 1024 * 1024

    /// One line of the file, carrying enough context for a caller to tell a
    /// whole record from a salvaged prefix.
    struct Line {
        /// The line's bytes, newline and any CRLF carriage return excluded. For
        /// an oversized line this is only the leading `prefixBytes`.
        let bytes: Data
        /// The line's full on-disk length excluding the newline, even when only
        /// a prefix was retained.
        let byteCount: Int
        /// `true` when the line exceeded `maxLineBytes` and `bytes` is a prefix.
        /// Callers should still try to parse it: a truncated record whose usage
        /// fields survived is real spend and must be counted.
        let wasTruncated: Bool
    }

    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")

    /// Invokes `body` once per line, without the trailing newline.
    ///
    /// `body` is a non-escaping function parameter on purpose: the Codex scan
    /// threads an `inout` accumulator through it, and capturing an `inout`
    /// parameter is only legal in a non-escaping closure. It stays non-escaping
    /// through the nested `withUnsafeBytes` below, whose closure is itself
    /// non-escaping.
    ///
    /// Lines are cut straight out of the chunk the read produced. Nothing is
    /// buffered unless a line actually straddles two chunks, and the newline
    /// search runs on `memchr` rather than `Data`'s byte-at-a-time `Collection`
    /// conformance. On an 820 MB Codex rollout (4754 lines, the longest 56.7 MB)
    /// that is the difference between 69.8s and 0.4s.
    ///
    /// - Parameters:
    ///   - maxLineBytes: Bytes buffered for a single line. A line at or under
    ///     this length arrives whole; past it the reader stops appending and
    ///     only keeps counting, so peak retention never tracks line length.
    ///   - prefixBytes: Bytes of an oversized line handed to `body`. Clamped to
    ///     `maxLineBytes`, since nothing beyond that was ever buffered.
    /// - Returns: `false` when the file could not be opened, `true` otherwise.
    ///   An empty file opens successfully and yields nothing.
    @discardableResult
    static func forEachLine(
        in url: URL,
        chunkSize: Int = defaultChunkSize,
        maxLineBytes: Int = defaultMaxLineBytes,
        prefixBytes: Int = defaultPrefixBytes,
        _ body: (Line) -> Void
    ) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        // Guards against a caller passing 0 and spinning forever on empty reads.
        let size = max(1, chunkSize)
        let cap = max(0, maxLineBytes)
        let prefix = min(max(0, prefixBytes), cap)

        var retained = Data()
        var byteCount = 0

        // Counts every byte of the line but stops copying once the cap is hit.
        func absorb(_ start: UnsafePointer<UInt8>, count: Int) {
            byteCount += count
            guard retained.count < cap else { return }
            let room = cap - retained.count
            retained.append(start, count: min(count, room))
        }

        func emitRetained() {
            body(Self.line(retained, byteCount: byteCount, prefixBytes: prefix))
            retained = Data()
            byteCount = 0
        }

        while let chunk = try? handle.read(upToCount: size), !chunk.isEmpty {
            chunk.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var cursor = 0

                while cursor < raw.count,
                      let hit = memchr(base + cursor, Int32(Self.newline), raw.count - cursor) {
                    let newlineOffset = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                    let segmentCount = newlineOffset - cursor
                    if byteCount == 0, segmentCount <= cap {
                        body(Self.line(base + cursor, count: segmentCount))
                    } else {
                        absorb(base + cursor, count: segmentCount)
                        emitRetained()
                    }
                    cursor = newlineOffset + 1
                }

                // Whatever trails the last newline belongs to the next line.
                // Retention stops at `cap`, while `byteCount` continues to track
                // the full on-disk length for the emitted metadata.
                if cursor < raw.count {
                    absorb(base + cursor, count: raw.count - cursor)
                }
            }
        }

        // A file ending in a newline leaves nothing pending; one that does not
        // still owes its final line.
        if byteCount > 0 {
            emitRetained()
        }
        return true
    }

    /// Builds the emitted line: trims an oversized buffer down to the salvage
    /// prefix, and drops a CRLF carriage return.
    ///
    /// The copies matter: slicing `Data` keeps the parent's non-zero
    /// `startIndex`, and `JSONSerialization` has historically mis-read offset
    /// slices. The carriage return is only stripped from a complete line — on a
    /// truncated one the last byte is an arbitrary mid-line byte, not a
    /// terminator.
    private static func line(_ retained: Data, byteCount: Int, prefixBytes: Int) -> Line {
        guard byteCount <= retained.count else {
            return Line(bytes: Data(retained.prefix(prefixBytes)), byteCount: byteCount, wasTruncated: true)
        }
        if retained.last == UInt8(ascii: "\r") {
            return Line(bytes: Data(retained.dropLast()), byteCount: byteCount, wasTruncated: false)
        }
        return Line(bytes: retained, byteCount: byteCount, wasTruncated: false)
    }

    /// Copies `count` bytes into a zero-based `Data` and drops a CRLF carriage
    /// return. The copy matters: handing out a pointer into the chunk would
    /// dangle the moment `withUnsafeBytes` returns, and a `Data` slice would
    /// keep the parent's non-zero `startIndex`, which `JSONSerialization` has
    /// historically mis-read.
    private static func line(_ start: UnsafePointer<UInt8>, count: Int) -> Line {
        var length = count
        if length > 0, start[length - 1] == carriageReturn {
            length -= 1
        }
        return Line(bytes: Data(bytes: start, count: length), byteCount: count, wasTruncated: false)
    }
}
