import Foundation

/// Parses the human-readable reset hint embedded in a Claude rate-limit
/// message ("resets 7:30am (Europe/Malta)") into an absolute instant.
///
/// The transcript never states a date, only a wall-clock time and (usually) an
/// IANA timezone. This parser resolves that clock time to the occurrence
/// *closest in time* to the rate-limit event, which is the only anchor we have.
/// Choosing the nearest occurrence — rather than always rolling forward — is
/// what keeps a "02:10 reset read at 02:15" from being mistaken for tomorrow
/// (#96). The parser deliberately does **not** decide whether quota is
/// available; a returned instant in the past means "already elapsed, re-check",
/// never "proven available".
nonisolated enum TranscriptResetParser {
    struct Result: Equatable, Sendable {
        /// The absolute reset instant, anchored to the event timestamp.
        let resetAt: Date
        /// The timezone the transcript named, if any (nil ⇒ current zone used).
        let timeZoneIdentifier: String?

        /// Whether `resetAt` already elapsed relative to the anchoring event.
        /// A past reset may schedule a refresh but can never prove availability.
        func isElapsed(relativeTo reference: Date) -> Bool {
            resetAt <= reference
        }
    }

    // "resets 7:30am (Europe/Malta)" / "resets 2:10am" / "resets **2:10am ...**"
    private static let pattern = try? NSRegularExpression(
        pattern: #"resets\s*\**\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*\**\s*(?:\(([^)]+)\))?"#,
        options: [.caseInsensitive]
    )

    /// Parse `messageText`, anchoring the clock time to `eventTimestamp`.
    ///
    /// - Returns: the nearest absolute occurrence of the stated clock time, or
    ///   nil when no reset hint is present.
    static func parse(messageText: String, eventTimestamp: Date) -> Result? {
        guard let pattern else { return nil }
        let range = NSRange(messageText.startIndex..., in: messageText)
        guard let match = pattern.firstMatch(in: messageText, range: range) else {
            return nil
        }

        func group(_ index: Int) -> String? {
            guard match.numberOfRanges > index,
                  let r = Range(match.range(at: index), in: messageText) else {
                return nil
            }
            return String(messageText[r])
        }

        guard let hourString = group(1), let rawHour = Int(hourString) else {
            return nil
        }
        let minute = group(2).flatMap(Int.init) ?? 0
        let meridiem = group(3)?.lowercased()
        let tzIdentifier = group(4)?.trimmingCharacters(in: .whitespaces)

        var hour = rawHour
        if let meridiem {
            if meridiem == "pm", hour < 12 { hour += 12 }
            if meridiem == "am", hour == 12 { hour = 0 }
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }

        let timeZone = tzIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // Build the clock time on the event's calendar day, then pick whichever
        // of {yesterday, today, tomorrow} lands closest to the event instant.
        var components = calendar.dateComponents([.year, .month, .day], from: eventTimestamp)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard let sameDay = calendar.date(from: components) else { return nil }

        let candidates = [-1, 0, 1].compactMap {
            calendar.date(byAdding: .day, value: $0, to: sameDay)
        }
        guard let nearest = candidates.min(by: {
            abs($0.timeIntervalSince(eventTimestamp)) < abs($1.timeIntervalSince(eventTimestamp))
        }) else {
            return nil
        }

        return Result(resetAt: nearest, timeZoneIdentifier: tzIdentifier)
    }
}
