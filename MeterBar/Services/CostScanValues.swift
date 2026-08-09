import Foundation
import MeterBarShared

/// Value coercion and display naming shared by the Claude and Codex scans.
/// Split out of `CostTracker` (audit C1d) so each rule is directly assertable
/// instead of reachable only through a full filesystem scan.
enum CostScanValues {
    /// Identifies the rules a cached scan digest was produced under.
    ///
    /// Bump this whenever a change alters parsed output: usage extraction,
    /// deduplication, pricing, model normalization, or local-day bucketing.
    /// A mismatch discards the persisted cache and performs a full rescan.
    nonisolated static let costCacheParserVersion = 3

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
