import Foundation

/// A typed reason a Claude Code session stopped on a usage limit.
///
/// The transcript only ever spells the reason in prose ("session limit",
/// "usage limit", "weekly limit"), so discovery maps that prose onto a closed
/// set the rest of Session Wake can gate on without re-parsing strings.
enum WakeBlockReason: String, Codable, Equatable, Sendable, CaseIterable {
    /// The rolling 5-hour session window ("You've hit your session limit").
    case sessionLimit
    /// A generic usage limit that is not explicitly the weekly window.
    case usageLimit
    /// A weekly account-wide limit ("weekly limit").
    case weeklyLimit
    /// A model-specific weekly limit (e.g. Opus) called out separately.
    case modelWeeklyLimit

    /// Classify a rate-limit message body into a typed reason.
    ///
    /// Casing and surrounding markdown are ignored; the first specific phrase
    /// wins so "opus weekly limit" is not collapsed into the generic weekly
    /// case, and "weekly" is preferred over the plain "usage limit" fallback.
    static func classify(messageText: String) -> WakeBlockReason {
        let text = messageText.lowercased()
        if text.contains("opus") && text.contains("weekly") {
            return .modelWeeklyLimit
        }
        if text.contains("weekly limit") || text.contains("weekly usage") {
            return .weeklyLimit
        }
        if text.contains("session limit") {
            return .sessionLimit
        }
        return .usageLimit
    }
}
