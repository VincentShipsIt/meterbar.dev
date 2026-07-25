import Foundation
import MeterBarShared

/// Value coercion and display naming shared by the Claude and Codex scans.
/// Split out of `CostTracker` (audit C1d) so each rule is directly assertable
/// instead of reachable only through a full filesystem scan.
enum CostScanValues {
    /// Token counts arrive as `Int`, `Int64`, `Double`, or a numeric string
    /// depending on which writer produced the log line; coerce every shape.
    nonisolated static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? Double { return Int(value) }
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
