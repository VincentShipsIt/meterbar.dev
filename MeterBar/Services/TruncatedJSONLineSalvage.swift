import Foundation

/// Pulls individual JSON values out of a window cut from a line too long to
/// retain whole.
///
/// Neither window a truncated line carries is parseable JSON: the prefix stops
/// mid-record and the tail starts mid-record. `JSONSerialization` rejects both,
/// so the fields a usage event needs have to be lifted out one at a time.
///
/// This is a heuristic and cannot be anything else. A tail begins at an
/// arbitrary byte, so there is no way to know from inside the window whether a
/// given quote opens or closes a string — a `"usage":` sequence appearing inside
/// a `content` string is indistinguishable from the real one. Two things keep it
/// honest: an extracted value must parse on its own, and the caller decides
/// which occurrence to trust (`usage` sits after `content` in every Claude
/// record, so the last match in the tail is the record's own). Both are why the
/// output is only ever used to recover accounting from a line that would
/// otherwise be dropped outright, never to override a line that parsed.
nonisolated enum TruncatedJSONLineSalvage {
    /// 64 KiB. Every field worth salvaging — a usage object, a timestamp, a
    /// model name — is orders of magnitude smaller; a candidate this large is a
    /// false positive that ran off into the record's content.
    static let maximumValueBytes = 64 * 1024

    /// Ceiling on candidates considered for one key, so a window full of
    /// `"usage"` occurrences cannot turn salvage into a quadratic scan.
    static let maximumMatches = 64

    /// Every value found for `key`, in the order they appear in `window`.
    static func values(forKey key: String, in window: Data, maximumMatches: Int = maximumMatches) -> [Any] {
        guard !window.isEmpty, !key.isEmpty else { return [] }
        let needle = Data("\"\(key)\"".utf8)
        var found: [Any] = []
        var searchStart = window.startIndex

        while found.count < maximumMatches, searchStart < window.endIndex,
              let match = window.range(of: needle, in: searchStart..<window.endIndex) {
            searchStart = match.upperBound
            guard let colon = Self.index(ofColonAfter: match.upperBound, in: window),
                  let value = Self.value(startingAfter: colon, in: window) else { continue }
            found.append(value)
        }
        return found
    }

    static func firstValue(forKey key: String, in window: Data) -> Any? {
        Self.values(forKey: key, in: window, maximumMatches: 1).first
    }

    static func lastValue(forKey key: String, in window: Data) -> Any? {
        Self.values(forKey: key, in: window).last
    }

    /// Index of the `:` that follows a key, or `nil` if anything but whitespace
    /// sits between the two — which means the match was a string, not a key.
    private static func index(ofColonAfter start: Data.Index, in window: Data) -> Data.Index? {
        var cursor = start
        while cursor < window.endIndex {
            switch window[cursor] {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"), UInt8(ascii: "\n"):
                cursor = window.index(after: cursor)
            case UInt8(ascii: ":"):
                return cursor
            default:
                return nil
            }
        }
        return nil
    }

    /// Decodes the value that begins after `colon`, bounded by
    /// ``maximumValueBytes`` and by the end of the window.
    private static func value(startingAfter colon: Data.Index, in window: Data) -> Any? {
        var cursor = window.index(after: colon)
        while cursor < window.endIndex, Self.isWhitespace(window[cursor]) {
            cursor = window.index(after: cursor)
        }
        guard cursor < window.endIndex else { return nil }
        let limit = window.index(cursor, offsetBy: maximumValueBytes, limitedBy: window.endIndex) ?? window.endIndex

        let end: Data.Index?
        switch window[cursor] {
        case UInt8(ascii: "{"):
            end = Self.balanced(
                from: cursor,
                to: limit,
                in: window,
                open: UInt8(ascii: "{"),
                close: UInt8(ascii: "}")
            )
        case UInt8(ascii: "["):
            end = Self.balanced(
                from: cursor,
                to: limit,
                in: window,
                open: UInt8(ascii: "["),
                close: UInt8(ascii: "]")
            )
        case UInt8(ascii: "\""):
            end = Self.quoted(from: cursor, to: limit, in: window)
        default:
            end = Self.literal(from: cursor, to: limit, in: window)
        }
        guard let end else { return nil }

        // Zero-based copy: `JSONSerialization` has historically mis-read slices
        // that carry a non-zero `startIndex`.
        let bytes = Data(window[cursor..<end])
        return try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
    }

    private static func balanced(
        from start: Data.Index,
        to limit: Data.Index,
        in window: Data,
        open: UInt8,
        close: UInt8
    ) -> Data.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var cursor = start

        while cursor < limit {
            let byte = window[cursor]
            cursor = window.index(after: cursor)
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
            case UInt8(ascii: "\""): inString = true
            case open: depth += 1
            case close:
                depth -= 1
                if depth == 0 { return cursor }
            default: break
            }
        }
        return nil
    }

    private static func quoted(from start: Data.Index, to limit: Data.Index, in window: Data) -> Data.Index? {
        var escaped = false
        var cursor = window.index(after: start)

        while cursor < limit {
            let byte = window[cursor]
            cursor = window.index(after: cursor)
            if escaped {
                escaped = false
                continue
            }
            switch byte {
            case UInt8(ascii: "\\"): escaped = true
            case UInt8(ascii: "\""): return cursor
            default: break
            }
        }
        return nil
    }

    /// End of a bare `true` / `false` / `null` / number. A literal running to the
    /// edge of the window was cut by the truncation and is not trustworthy, so
    /// only one terminated by a delimiter counts.
    private static func literal(from start: Data.Index, to limit: Data.Index, in window: Data) -> Data.Index? {
        var cursor = start
        while cursor < limit {
            let byte = window[cursor]
            if byte == UInt8(ascii: ",") || byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]")
                || Self.isWhitespace(byte) {
                return cursor > start ? cursor : nil
            }
            cursor = window.index(after: cursor)
        }
        return nil
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n")
    }
}
