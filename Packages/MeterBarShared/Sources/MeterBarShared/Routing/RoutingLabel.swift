import Foundation

/// The one gate every free-text label passes before it can reach routing
/// output.
///
/// Account names and task names are user-authored. People type an email
/// address as an account label, or a path, and `route --json` promises neither
/// ever appears. Rather than trust that nobody does, a label that looks like
/// either is replaced by a caller-supplied neutral fallback.
public enum RoutingLabel {
    public static let maximumLength = 60

    /// `raw` trimmed and length-capped, or `fallback` when it is empty or looks
    /// like an email address or a filesystem path.
    public static func sanitized(_ raw: String?, fallback: String) -> String {
        guard let raw else { return fallback }
        guard !raw.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
        }) else {
            return fallback
        }
        let trimmed = raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !trimmed.isEmpty else { return fallback }
        let forbidden: [Character] = ["@", "/", "\\"]
        guard !trimmed.contains(where: { forbidden.contains($0) }), !trimmed.hasPrefix("~") else {
            return fallback
        }
        return String(trimmed.prefix(maximumLength))
    }

    /// Neutral label for an account whose own name cannot be shown. Built from
    /// the stable account id so two such accounts stay distinguishable.
    public static func fallbackAccountLabel(id: UUID) -> String {
        "Account \(id.uuidString.prefix(8).lowercased())"
    }
}
