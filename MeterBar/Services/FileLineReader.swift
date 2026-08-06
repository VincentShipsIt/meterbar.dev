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

        // Guards against a caller passing 0 and spinning forever on empty reads.
        let size = max(1, chunkSize)
        // Holds only the head of a line whose newline has not arrived yet. A
        // file of ordinary lines never touches it, so the common path copies
        // each line exactly once — into the `Data` handed to `body` — and never
        // re-bases a buffer between chunks.
        var carry = Data()

        while let chunk = try? handle.read(upToCount: size), !chunk.isEmpty {
            chunk.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var cursor = 0

                while cursor < raw.count,
                      let hit = memchr(base + cursor, Int32(newline), raw.count - cursor) {
                    let newlineOffset = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                    if carry.isEmpty {
                        // Whole line lives in this chunk: emit it in place.
                        Self.emit(base + cursor, count: newlineOffset - cursor, body)
                    } else {
                        // Tail of a straddling line. `carry` is built purely by
                        // appending onto a fresh `Data`, so it is already
                        // zero-based and needs no re-copy before `body` — the
                        // offset-slice hazard that `JSONSerialization` trips on
                        // cannot arise here.
                        if newlineOffset > cursor {
                            carry.append(base + cursor, count: newlineOffset - cursor)
                        }
                        if carry.last == Self.carriageReturn { carry.removeLast() }
                        body(carry)
                        // Released rather than kept: one 56.7 MB line must not
                        // pin 56.7 MB for the rest of the scan, least of all
                        // with several transcripts scanning concurrently.
                        carry = Data()
                    }
                    cursor = newlineOffset + 1
                }

                if cursor < raw.count {
                    carry.append(base + cursor, count: raw.count - cursor)
                }
            }
        }

        if !carry.isEmpty {
            if carry.last == Self.carriageReturn { carry.removeLast() }
            body(carry)
        }
        return true
    }

    /// Copies `count` bytes into a zero-based `Data` and drops a CRLF carriage
    /// return. The copy matters: handing out a pointer into the chunk would
    /// dangle the moment `withUnsafeBytes` returns, and a `Data` slice would
    /// keep the parent's non-zero `startIndex`, which `JSONSerialization` has
    /// historically mis-read.
    private static func emit(_ start: UnsafePointer<UInt8>, count: Int, _ body: (Data) -> Void) {
        var length = count
        if length > 0, start[length - 1] == carriageReturn {
            length -= 1
        }
        body(Data(bytes: start, count: length))
    }
}
