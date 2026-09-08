import Foundation

/// Reads the SpaceXAI status page at `https://status.x.ai/`.
///
/// The page is a custom Next.js app, not Atlassian Statuspage: its
/// `api/v2/status.json` returns a 404 HTML page. Service health is
/// server-rendered as one `<a href="/slug">` card per service carrying a
/// `heading-2` name and a coloured chip (`text-text-success` / `caution` /
/// `danger` / `info` / `unavailable`). The only other machine-readable output
/// is the incident RSS at `feed.xml`, which does not list current service state.
///
/// Chip colours are mapped onto the Statuspage component vocabulary so the
/// existing `ProviderStatusComponent` labels and ranking apply unchanged.
enum SpaceXAIStatusPageParser {
    static let noIncidentsHeadline = "No incidents declared"

    struct Parsed: Equatable {
        let summary: ProviderStatusSummary
        let components: [ProviderStatusComponent]
    }

    static func parse(html: String) throws -> Parsed {
        let components = parseComponents(html: html)
        guard !components.isEmpty else {
            throw ServiceError.parsingError("The SpaceXAI status page did not list any services")
        }

        let headline = firstMatch(of: headlinePattern, in: html)
            .map(cleanText)
            .flatMap { $0.isEmpty ? nil : $0 }

        // The banner tracks *declared incidents*; the service grid tracks
        // *current state*. They are independent sections of the page, so a
        // "No incidents declared" banner must never override a component
        // that is reporting degraded or unavailable (issue #535). Component
        // state is authoritative for the indicator whenever the banner is
        // the healthy one; otherwise an incident is declared but couldn't be
        // attributed to a specific component, so an all-healthy component
        // read is not trusted either.
        let isNoIncidentsBanner = headline?.caseInsensitiveCompare(noIncidentsHeadline) == .orderedSame
        let worst = components.map(\.indicator).max { $0.rank < $1.rank } ?? .unknown
        let indicator: ProviderStatusIndicator = isNoIncidentsBanner ? worst : (worst == .none ? .unknown : worst)

        return Parsed(
            summary: ProviderStatusSummary(
                indicator: indicator,
                description: headline ?? (indicator == .none ? noIncidentsHeadline : nil),
                updatedAt: nil
            ),
            components: components
        )
    }

    // MARK: - Components

    private static func parseComponents(html: String) -> [ProviderStatusComponent] {
        guard let regex = try? NSRegularExpression(pattern: cardPattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        // Anchor matching to the service grid so an unrelated `<a href>` in
        // navigation or footer markup earlier on the page cannot supply a
        // card's slug — `ProviderStatusComponent.id` is the SwiftUI
        // `Identifiable` key (issue #535). A page whose grid heading has
        // drifted beyond recognition yields no components, which surfaces as
        // `parsingError` rather than a guess.
        guard let range = serviceGridRange(in: html) else {
            return []
        }
        return regex.matches(in: html, range: range).compactMap { match in
            guard match.numberOfRanges == 5,
                  let slug = substring(html, match.range(at: 1)),
                  let rawName = substring(html, match.range(at: 2)),
                  let chipClasses = substring(html, match.range(at: 3)),
                  let rawLabel = substring(html, match.range(at: 4))
            else {
                return nil
            }
            let name = cleanText(rawName)
            guard !name.isEmpty else { return nil }
            let status = statuspageStatus(chipClasses: chipClasses, label: cleanText(rawLabel))
            return ProviderStatusComponent(
                id: slug,
                name: name,
                indicator: .componentIndicator(for: status),
                status: status
            )
        }
    }

    /// One service card: `<a … href="/slug">…<div class="heading-2">Name</div>…<div class="… text-text-tone">label</div></a>`.
    ///
    /// Every wildcard is written as `(?:(?!</a>).)*?` rather than a bare
    /// `.*?` so the match can never cross a `</a>` boundary. Without that
    /// bound, a card whose chip markup has drifted (no `text-text-*` class)
    /// makes the lazy `.*?` skip forward past that card's own `</a>` close
    /// and the next card's `<a>` open to find the *next* card's chip,
    /// pairing this card's name with a neighbour's status and silently
    /// dropping the neighbour (issue #535). Bounding to the card region
    /// means a drifted card simply fails to match at all — it is dropped,
    /// never merged — which is the fail-toward-unavailable behaviour
    /// unofficial provider surfaces require.
    private static let cardPattern =
        #"<a\b[^>]*\bhref="/([A-Za-z0-9_-]+)"[^>]*>(?:(?!</a>).)*?<div class="heading-2">((?:(?!</a>).)*?)</div>"#
        + #"(?:(?!</a>).)*?<div class="([^"]*\btext-text-[a-z]+[^"]*)"[^>]*>((?:(?!</a>).)*?)</div>\s*</a>"#

    /// Heading that marks the start of the service grid: `<h2 …>Services</h2>`.
    /// Card matching is restricted to everything after this heading so an
    /// earlier `<a href>` (nav, footer) cannot supply a card's slug.
    private static let serviceGridAnchorPattern = #"<h2\b[^>]*>\s*Services\s*</h2>"#

    /// Headline of the incident banner above the service grid.
    private static let headlinePattern = #"<h3 class="heading-3">(.*?)</h3>"#

    /// The portion of the page at and after the service grid heading, or
    /// `nil` if that heading cannot be found — in which case no cards are
    /// parsed rather than risking a card matched against unrelated markup.
    private static func serviceGridRange(in html: String) -> NSRange? {
        guard let anchor = try? NSRegularExpression(pattern: serviceGridAnchorPattern) else {
            return nil
        }
        let fullRange = NSRange(html.startIndex..., in: html)
        guard let anchorMatch = anchor.firstMatch(in: html, range: fullRange) else {
            return nil
        }
        let start = anchorMatch.range.location + anchorMatch.range.length
        let length = fullRange.length - start
        guard length > 0 else { return nil }
        return NSRange(location: start, length: length)
    }

    private static func statuspageStatus(chipClasses: String, label: String) -> String {
        let tone = firstMatch(of: #"text-text-([a-z]+)"#, in: chipClasses) ?? ""
        let lowered = label.lowercased()
        switch tone {
        case "success":
            return "operational"
        case "caution":
            return "degraded_performance"
        case "danger":
            return lowered.contains("unavailable") || lowered.contains("down") ? "major_outage" : "partial_outage"
        case "unavailable":
            return "major_outage"
        case "info":
            return "under_maintenance"
        default:
            return lowered.isEmpty ? "unknown" : lowered
        }
    }

    // MARK: - Helpers

    private static func firstMatch(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 2 else {
            return nil
        }
        return substring(text, match.range(at: 1))
    }

    private static func substring(_ text: String, _ range: NSRange) -> String? {
        guard let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private static func cleanText(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return stripped
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
