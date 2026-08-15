import Foundation
import MeterBarShared

/// Value coercion and display naming shared by the Claude, Codex, and Grok scans.
/// Split out of `CostTracker` (audit C1d) so each rule is directly assertable
/// instead of reachable only through a full filesystem scan.
enum CostScanValues {
    /// Identifies the rules a cached scan digest was produced under.
    ///
    /// Bump this whenever a change alters parsed output: usage extraction,
    /// deduplication, pricing, model normalization, or local-day bucketing.
    /// A mismatch discards the persisted cache and performs a full rescan.
    nonisolated static let costCacheParserVersion = 5

    /// Token counts arrive as `Int`, `Int64`, `Double`, or a numeric string
    /// depending on which writer produced the log line; coerce every shape.
    nonisolated static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        // `Int(Double)` traps on NaN, infinities, and anything outside Int's
        // range. These logs are written by third-party CLIs, so one malformed
        // line would otherwise crash the entire refresh — saturate instead.
        if let value = value as? Double {
            guard !value.isNaN else { return 0 }
            guard value > Double(Int.min) else { return Int.min }
            guard value < Double(Int.max) else { return Int.max }
            return Int(value)
        }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    /// Whole milliseconds since the epoch, or `nil` when the value cannot be
    /// expressed as one. `Int(_:)` traps on a `Double` outside `Int`'s range and
    /// `isFinite` does not rule that out — `1e300` is finite, and its
    /// millisecond value (~1e303) crashed the Grok scan on the way into the
    /// dedup key.
    ///
    /// Codex timestamps arrive as bounded ISO-8601 strings and Grok's as a raw
    /// JSON number, so only Grok can carry one today. Both go through this
    /// anyway: the bound is a property of the conversion, not of the writer, and
    /// "this parser can never emit an absurd date" is not a claim worth a trap.
    nonisolated static func millisecondsSinceEpoch(_ seconds: Double) -> Int? {
        let milliseconds = (seconds * 1000).rounded()
        guard milliseconds.isFinite,
              milliseconds >= Double(Int.min),
              milliseconds < Double(Int.max) else { return nil }
        return Int(milliseconds)
    }

    /// The attribution-free dedup key the Codex and Grok scans share.
    ///
    /// Whole-millisecond precision so equivalent events produce a stable,
    /// collision-resistant string; raw `Double` formatting can vary and risks
    /// both false matches and false misses.
    ///
    /// Model, origin, and project are deliberately absent. Codex's deferred
    /// back-fill replays a parked event once its rollout finally names a model,
    /// and a budgeted slice that ends with events still parked rolls its offset
    /// back so the next refresh re-reads them — both hand the same charge to
    /// `apply` twice under different attribution, and only an attribution-free
    /// key sees through it. The price is that two distinct same-millisecond
    /// events with identical counts collapse into one. `CostScanCorpusTests`
    /// pins both halves; widen this key only with a proof that the deferred
    /// path still dedups.
    ///
    /// - Parameter counts: Token counts in a fixed provider-specific order,
    ///   joined after the timestamp and session. Codex passes input, cached,
    ///   output, reasoning; Grok appends its cost ticks. Order is part of the
    ///   key — reordering it silently stops matching previously cached events.
    /// - Returns: `nil` when the timestamp cannot be expressed in whole
    ///   milliseconds, which means the record is corrupt and must be dropped.
    nonisolated static func deduplicationKey(
        timestamp: Date,
        sessionID: String,
        counts: [Int]
    ) -> String? {
        guard let milliseconds = millisecondsSinceEpoch(timestamp.timeIntervalSince1970) else { return nil }
        var key = "\(milliseconds)-\(sessionID)"
        for count in counts {
            key += "-\(count)"
        }
        return key
    }

    nonisolated static func displayModelName(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unknown model" : ModelPricing.normalizeClaudeModel(trimmed)
    }

    nonisolated static func displayOriginName(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "Unknown origin" }
        return trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
    }
}
