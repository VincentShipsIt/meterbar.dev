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
        let indicator: ProviderStatusIndicator
        if headline?.caseInsensitiveCompare(noIncidentsHeadline) == .orderedSame {
            indicator = .none
        } else {
            let worst = components.map(\.indicator).max { $0.rank < $1.rank } ?? .unknown
            indicator = worst == .none ? .unknown : worst
        }

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
        let range = NSRange(html.startIndex..., in: html)
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
    private static let cardPattern =
        #"<a\b[^>]*\bhref="/([A-Za-z0-9_-]+)"[^>]*>.*?<div class="heading-2">(.*?)</div>.*?"#
        + #"<div class="([^"]*\btext-text-[a-z]+[^"]*)"[^>]*>(.*?)</div>\s*</a>"#

    /// Headline of the incident banner above the service grid.
    private static let headlinePattern = #"<h3 class="heading-3">(.*?)</h3>"#

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
