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

    // Two accepted shapes, both anchored to the event:
    //   Time-of-day: "resets 7:30am (Europe/Malta)" / "resets 2:10am" /
    //                "resets **2:10am ...**" / "resets 19:00"
    //   Explicit date (weekly limits): "resets Jul 15 at 10pm (Europe/Malta)" /
    //                "resets Jan 2, 2027 at 9am"
    private static let pattern = try? NSRegularExpression(
        pattern: #"resets\s*\**\s*"# +
            #"(?:(?<month>jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+"# +
            #"(?<day>\d{1,2})(?:,\s*(?<year>\d{4}))?\s+at\s+)?"# +
            #"(?<hour>\d{1,2})(?::(?<minute>\d{2}))?\s*(?<ampm>am|pm)?\s*\**\s*"# +
            #"(?:\((?<zone>[^)]+)\))?"#,
        options: [.caseInsensitive]
    )

    /// Parse `messageText`, anchoring the reset to `eventTimestamp`.
    ///
    /// - Returns: the absolute reset instant — the nearest occurrence of a bare
    ///   clock time, or the stated calendar date for an explicit month/day — or
    ///   nil when no reset hint is present.
    static func parse(messageText: String, eventTimestamp: Date) -> Result? {
        guard let pattern else { return nil }
        let range = NSRange(messageText.startIndex..., in: messageText)
        guard let match = pattern.firstMatch(in: messageText, range: range) else {
            return nil
        }

        func group(_ name: String) -> String? {
            let r = match.range(withName: name)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: messageText) else {
                return nil
            }
            return String(messageText[swiftRange])
        }

        guard let hourString = group("hour"), let rawHour = Int(hourString) else {
            return nil
        }
        let minute = group("minute").flatMap(Int.init) ?? 0
        let meridiem = group("ampm")?.lowercased()
        let tzIdentifier = group("zone")?.trimmingCharacters(in: .whitespaces)

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

        var components = calendar.dateComponents([.year, .month, .day], from: eventTimestamp)
        components.hour = hour
        components.minute = minute
        components.second = 0

        // A weekly limit names a calendar date; a session limit names only a
        // clock time. They resolve differently, so dispatch on the month group.
        let resetAt: Date?
        if let month = group("month").flatMap(Self.monthNumber(fromAbbreviation:)) {
            resetAt = explicitDate(
                month: month,
                day: group("day").flatMap(Int.init),
                explicitYear: group("year").flatMap(Int.init),
                base: components,
                calendar: calendar,
                eventTimestamp: eventTimestamp
            )
        } else {
            resetAt = nearestOccurrence(of: components, calendar: calendar, eventTimestamp: eventTimestamp)
        }

        guard let resetAt else { return nil }
        return Result(resetAt: resetAt, timeZoneIdentifier: tzIdentifier)
    }

    /// Resolve an explicit month/day(/year) reset. With no stated year the date
    /// is anchored to the event's year and rolled forward a *whole year* when it
    /// lands well before the event — a December block whose reset reads "Jan 2"
    /// is next January, never this year's elapsed one.
    private static func explicitDate(
        month: Int,
        day: Int?,
        explicitYear: Int?,
        base: DateComponents,
        calendar: Calendar,
        eventTimestamp: Date
    ) -> Date? {
        var components = base
        components.month = month
        if let day {
            // Calendar.date(from:) silently normalizes overflow ("Jul 32" →
            // Aug 1); reject impossible days like the hour/minute guards do.
            guard (1...31).contains(day) else { return nil }
            components.day = day
        }
        if let explicitYear { components.year = explicitYear }
        guard let resolved = calendar.date(from: components) else { return nil }
        // A stated year is authoritative; only an inferred year rolls forward,
        // and only when the shortfall exceeds what display rounding or a
        // timezone-fallback skew could explain. Within the tolerance the past
        // instant is returned as-is — the contract treats an elapsed reset as
        // "re-check now", which is safe; a +1-year instant is not.
        guard explicitYear == nil,
              resolved < eventTimestamp - rolloverSkewTolerance else { return resolved }
        return calendar.date(byAdding: .year, value: 1, to: resolved)
    }

    /// How far in the past an inferred-year month/day reset may land before we
    /// assume it means *next* year rather than clock/display skew (2 days).
    private static let rolloverSkewTolerance: TimeInterval = 2 * 86_400

    /// Resolve a bare clock time to whichever of {yesterday, today, tomorrow}
    /// lands closest to the event instant. Choosing the nearest occurrence —
    /// rather than always rolling forward — keeps a "02:10 reset read at 02:15"
    /// from being mistaken for tomorrow (#96).
    private static func nearestOccurrence(
        of components: DateComponents,
        calendar: Calendar,
        eventTimestamp: Date
    ) -> Date? {
        guard let sameDay = calendar.date(from: components) else { return nil }
        let candidates = [-1, 0, 1].compactMap {
            calendar.date(byAdding: .day, value: $0, to: sameDay)
        }
        return candidates.min(by: {
            abs($0.timeIntervalSince(eventTimestamp)) < abs($1.timeIntervalSince(eventTimestamp))
        })
    }

    private static func monthNumber(fromAbbreviation value: String) -> Int? {
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let index = months.firstIndex(of: String(value.lowercased().prefix(3))) else {
            return nil
        }
        return index + 1
    }
}
