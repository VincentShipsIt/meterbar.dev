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

    /// Maximum bytes retained for one line while its full on-disk length keeps
    /// being counted for offsets and truncation metadata.
    var maxLineBytes: Int = FileLineReader.defaultMaxLineBytes

    /// Leading bytes of an oversized line passed to the parser.
    var prefixBytes: Int = FileLineReader.defaultPrefixBytes

    /// Trailing bytes of an oversized line kept alongside the prefix.
    var salvageTailBytes: Int = FileLineReader.defaultSalvageTailBytes

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

    /// 256 KiB — the trailing window of an oversized line kept for salvage.
    ///
    /// A Claude transcript record orders `content` before `usage` and puts the
    /// top-level `timestamp` after the whole message object, so a line made
    /// oversized by its content strands both fields the accounting needs past
    /// the prefix cut. They sit within the last few hundred bytes of the record;
    /// this window reaches them without retention ever tracking line length.
    static let defaultSalvageTailBytes = 256 * 1024

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
        /// The last `salvageTailBytes` of a truncated line, cut at an arbitrary
        /// byte. Empty whenever `wasTruncated` is `false`. It is not valid JSON
        /// on its own — only ``TruncatedJSONLineSalvage`` should read it.
        let truncatedTail: Data

        init(bytes: Data, byteCount: Int, wasTruncated: Bool, truncatedTail: Data = Data()) {
            self.bytes = bytes
            self.byteCount = byteCount
            self.wasTruncated = wasTruncated
            self.truncatedTail = truncatedTail
        }
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
    ///   - salvageTailBytes: Trailing bytes of an oversized line kept alongside
    ///     the prefix, for the fields that sit past the cut.
    /// - Returns: `false` when the file could not be opened, `true` otherwise.
    ///   An empty file opens successfully and yields nothing.
    @discardableResult
    static func forEachLine(
        in url: URL,
        chunkSize: Int = defaultChunkSize,
        maxLineBytes: Int = defaultMaxLineBytes,
        prefixBytes: Int = defaultPrefixBytes,
        salvageTailBytes: Int = defaultSalvageTailBytes,
        _ body: (Line) -> Void
    ) -> Bool {
        var request = FileLineReadRequest()
        request.chunkSize = chunkSize
        request.maxLineBytes = maxLineBytes
        request.prefixBytes = prefixBytes
        request.salvageTailBytes = salvageTailBytes
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
        _ body: (Line, UInt64) -> Void
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

        // Guards against a caller passing 0 and spinning forever on empty reads.
        let chunkSize = max(1, request.chunkSize)
        let cap = max(0, request.maxLineBytes)
        let prefix = min(max(0, request.prefixBytes), cap)
        let tail = max(0, request.salvageTailBytes)
        let budget = max(0, request.maxBytes)
        var committed = request.startOffset
        var bytesRead = 0
        var reachedEnd = false
        var retained = Data()
        var overflow = Data()
        var byteCount = 0

        // Counts every byte of the line but stops copying once the cap is hit.
        // Past the cap a rolling window of the most recent bytes is kept, halved
        // back to `tail` whenever it doubles, so both buffers stay flat no matter
        // how long the line runs.
        func absorb(_ start: UnsafePointer<UInt8>, count: Int) {
            byteCount += count
            var consumed = 0
            if retained.count < cap {
                consumed = min(count, cap - retained.count)
                retained.append(start, count: consumed)
            }
            guard tail > 0, consumed < count else { return }
            overflow.append(start + consumed, count: count - consumed)
            if overflow.count > 2 * tail {
                overflow = Data(overflow.suffix(tail))
            }
        }

        func emitRetained(hasNewline: Bool) {
            let line = Self.line(
                retained, overflow: overflow, byteCount: byteCount, prefixBytes: prefix, tailBytes: tail
            )
            body(line, committed)
            committed += UInt64(byteCount + (hasNewline ? 1 : 0))
            retained = Data()
            overflow = Data()
            byteCount = 0
        }

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
            chunk.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var cursor = 0

                while cursor < raw.count,
                      let hit = memchr(base + cursor, Int32(Self.newline), raw.count - cursor) {
                    let newlineOffset = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                    let segmentCount = newlineOffset - cursor
                    if byteCount == 0, segmentCount <= cap {
                        body(Self.line(base + cursor, count: segmentCount), committed)
                        committed += UInt64(segmentCount) + 1
                    } else {
                        absorb(base + cursor, count: segmentCount)
                        emitRetained(hasNewline: true)
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

        // A residual left behind because the budget ran out is a line the file
        // continues past — never commit it, even when the bytes read so far
        // happen to look like complete JSON.
        let stoppedForBudget = !reachedEnd && bytesRead >= budget
        if byteCount > 0, !stoppedForBudget {
            let line = Self.line(
                retained, overflow: overflow, byteCount: byteCount, prefixBytes: prefix, tailBytes: tail
            )
            if request.commitsUnterminatedTrailingLine
                || (!line.wasTruncated && isStructurallyCompleteJSONLine(line.bytes)) {
                emitRetained(hasNewline: false)
            }
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

    /// Builds the emitted line: trims an oversized buffer down to the salvage
    /// prefix and its trailing window, and drops a CRLF carriage return.
    ///
    /// The copies matter: slicing `Data` keeps the parent's non-zero
    /// `startIndex`, and `JSONSerialization` has historically mis-read offset
    /// slices. The carriage return is only stripped from a complete line — on a
    /// truncated one the last byte is an arbitrary mid-line byte, not a
    /// terminator.
    private static func line(
        _ retained: Data,
        overflow: Data,
        byteCount: Int,
        prefixBytes: Int,
        tailBytes: Int
    ) -> Line {
        guard byteCount <= retained.count else {
            return Line(
                bytes: Data(retained.prefix(prefixBytes)),
                byteCount: byteCount,
                wasTruncated: true,
                truncatedTail: Data(overflow.suffix(tailBytes))
            )
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
