import Foundation

/// Names the Codex reserve pool that serves requests once a plan's own quota is
/// spent.
///
/// The name is never in the payload. OpenAI reports `limit_name: "gpt-reserve"`
/// and `normal_model_slug: "gpt-5.6-luna"`, and the Codex CLI composes "Luna
/// Reserve" from them. MeterBar derives it the same way rather than hardcoding
/// the model of the month: the reserve was Luna in September 2026 and the slug
/// is what will change when it is not.
nonisolated enum CodexReserveLabel {
    /// Word appended to the model family. Not localized — it is half of a
    /// provider-supplied proper name, like the "Reserve" the Codex CLI prints.
    private static let suffix = "Reserve"

    /// Slug components that name a vendor rather than a model family, so
    /// `gpt-reserve` does not become "Gpt Reserve".
    private static let acronyms: Set<String> = ["gpt", "openai", "oai"]

    /// A display name for the reserve, or `nil` when neither field can name it.
    ///
    /// `nil` means no row: an unnamed bar next to the weekly one tells the user
    /// less than nothing about which pool is still serving them.
    static func make(modelSlug: String?, limitName: String?) -> String? {
        if let family = family(fromModelSlug: modelSlug) {
            return "\(family) \(suffix)"
        }
        return humanized(limitName)
    }

    /// The family word of a model slug: the last component that is purely
    /// alphabetic, so `gpt-5.6-luna` reads as "Luna" and a bare version tail
    /// like `gpt-5.6` names nothing.
    private static func family(fromModelSlug slug: String?) -> String? {
        guard let slug else { return nil }
        let components = slug
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." })
            .map(String.init)
        guard let tail = components.last(where: { component in
            component.allSatisfy(\.isLetter) && !acronyms.contains(component.lowercased())
        }) else {
            return nil
        }
        return capitalizedFirst(tail)
    }

    /// Falls back to the internal limit name — `gpt-reserve` → "GPT Reserve" —
    /// keeping a name that is at least the provider's own. A name that already
    /// ends in "Reserve" is not given a second one.
    private static func humanized(_ limitName: String?) -> String? {
        guard let limitName else { return nil }
        let words = limitName
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { component -> String in
                let word = String(component)
                return acronyms.contains(word.lowercased()) ? word.uppercased() : capitalizedFirst(word)
            }
        guard !words.isEmpty else { return nil }
        let joined = words.joined(separator: " ")
        guard words.last?.caseInsensitiveCompare(suffix) != .orderedSame else { return joined }
        return "\(joined) \(suffix)"
    }

    /// Uppercases the first character only. `String.capitalized` would lowercase
    /// the rest, turning a provider's own casing into something it never wrote.
    private static func capitalizedFirst(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }
}
