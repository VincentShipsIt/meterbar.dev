import Foundation

/// API token prices in USD per million tokens.
public struct TokenPricing: Equatable, Sendable {
    public let input: Double
    public let output: Double
    public let cacheCreation: Double
    public let cacheRead: Double
    public let cacheCreationOneHour: Double?

    public init(
        input: Double,
        output: Double,
        cacheCreation: Double,
        cacheRead: Double,
        cacheCreationOneHour: Double? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.cacheCreationOneHour = cacheCreationOneHour
    }
}

/// One rate card and the date it took effect, so an event recorded months ago
/// is priced at the rate that was published then rather than today's.
public struct DatedTokenPricing: Equatable, Sendable {
    /// Inclusive: an event stamped exactly at this instant uses this entry.
    public let effectiveFrom: Date
    /// The day this row was checked against the provider's pricing page.
    public let verifiedOn: String
    public let pricing: TokenPricing

    public init(effectiveFrom: Date, verifiedOn: String, pricing: TokenPricing) {
        self.effectiveFrom = effectiveFrom
        self.verifiedOn = verifiedOn
        self.pricing = pricing
    }

    /// UTC midnight for a table entry, written as `(2026, 7, 2)` so entries read
    /// like the pricing pages they were copied from.
    public static func utcDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components) ?? .distantPast
    }
}

/// The rate that applied to one event, plus where it came from.
public struct ResolvedPricing: Equatable, Sendable {
    public let pricing: TokenPricing
    public let effectiveFrom: Date
    public let verifiedOn: String
    /// The event predates every entry we have, so it was priced at the oldest
    /// known rate. Surfaced in scan diagnostics rather than failing the scan.
    public let precedesFirstEntry: Bool

    public init(pricing: TokenPricing, effectiveFrom: Date, verifiedOn: String, precedesFirstEntry: Bool) {
        self.pricing = pricing
        self.effectiveFrom = effectiveFrom
        self.verifiedOn = verifiedOn
        self.precedesFirstEntry = precedesFirstEntry
    }
}

/// Date-ranged rates for one model key. Entries are half-open ranges: each one
/// applies from its `effectiveFrom` until the next entry begins, and the last
/// entry stays open-ended.
public struct PricingSchedule: Equatable, Sendable {
    /// Always sorted ascending by `effectiveFrom`.
    public let entries: [DatedTokenPricing]

    public init(_ entries: [DatedTokenPricing]) {
        self.entries = entries.sorted { $0.effectiveFrom < $1.effectiveFrom }
    }

    /// A rate that has always applied, for models whose historical prices we
    /// never verified. Open-ended backwards so no event is ever flagged as
    /// pre-history against a fabricated start date.
    public static func constant(_ pricing: TokenPricing, verifiedOn: String) -> PricingSchedule {
        PricingSchedule([
            DatedTokenPricing(effectiveFrom: .distantPast, verifiedOn: verifiedOn, pricing: pricing)
        ])
    }

    /// The entry in effect at `timestamp`, or the oldest entry (flagged) when
    /// the event predates the whole schedule. `nil` only for an empty schedule —
    /// callers must fall back rather than price at zero.
    public func resolve(at timestamp: Date) -> ResolvedPricing? {
        guard let oldest = entries.first else { return nil }

        var chosen = oldest
        for entry in entries {
            // Ascending order means the first entry that starts after the
            // requested date ends the search — nothing later can apply.
            guard entry.effectiveFrom <= timestamp else { break }
            chosen = entry
        }

        return ResolvedPricing(
            pricing: chosen.pricing,
            effectiveFrom: chosen.effectiveFrom,
            verifiedOn: chosen.verifiedOn,
            precedesFirstEntry: timestamp < oldest.effectiveFrom
        )
    }
}

/// Which rate entries a scan actually used, so the UI and CLI can name the
/// verification date of the entry in play instead of one global revision date.
public struct PricingProvenance: Codable, Equatable, Sendable {
    /// Unique and sorted ascending; a scan spanning a rate change carries both.
    public private(set) var verificationDates: [String]
    /// Events priced at the oldest known rate because they predate the table.
    public private(set) var eventsBeforeFirstEntry: Int

    public init(verificationDates: [String] = [], eventsBeforeFirstEntry: Int = 0) {
        self.verificationDates = Array(Set(verificationDates)).sorted()
        self.eventsBeforeFirstEntry = max(0, eventsBeforeFirstEntry)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            verificationDates: try container.decodeIfPresent([String].self, forKey: .verificationDates) ?? [],
            eventsBeforeFirstEntry: try container.decodeIfPresent(Int.self, forKey: .eventsBeforeFirstEntry) ?? 0
        )
    }

    public var isEmpty: Bool {
        verificationDates.isEmpty && eventsBeforeFirstEntry == 0
    }

    /// "Rates verified 2026-07-02", or a range when the scan crossed entries
    /// checked on different days.
    public var label: String {
        guard let first = verificationDates.first, let last = verificationDates.last else {
            return "Rates verified —"
        }
        return first == last ? "Rates verified \(first)" : "Rates verified \(first)–\(last)"
    }

    /// Non-nil only when something was priced at the oldest known rate.
    public var diagnosticNote: String? {
        guard eventsBeforeFirstEntry > 0 else { return nil }
        let events = eventsBeforeFirstEntry == 1 ? "1 event" : "\(eventsBeforeFirstEntry) events"
        return "\(events) predate the pricing table and were priced at the oldest known rate."
    }

    public mutating func record(_ resolved: ResolvedPricing) {
        insert(resolved.verifiedOn)
        if resolved.precedesFirstEntry {
            eventsBeforeFirstEntry += 1
        }
    }

    public mutating func merge(_ other: PricingProvenance) {
        for date in other.verificationDates {
            insert(date)
        }
        eventsBeforeFirstEntry += other.eventsBeforeFirstEntry
    }

    private mutating func insert(_ date: String) {
        guard !verificationDates.contains(date) else { return }
        verificationDates.append(date)
        verificationDates.sort()
    }
}

/// Single source of truth for the app, widget, and CLI's local-log cost
/// estimates. Every model key maps to date-ranged rates; look-ups take the
/// event's timestamp so historical sessions keep the price they were billed at.
///
/// Sources:
///   - Anthropic, checked 2026-07-02 — https://www.anthropic.com/pricing#api
///   - OpenAI (Codex CLI slugs), checked 2026-07-02 — https://openai.com/api/pricing/
///   - OpenAI (admin-usage-API models: `openai-*` keys below), checked
///     2026-09-08 against each model's own page under
///     https://developers.openai.com/api/docs/models/ (redirected from
///     platform.openai.com/docs/pricing) — issue #554. `gpt-4-turbo`,
///     `gpt-4`, and `gpt-3.5-turbo` predate prompt caching and list no cached
///     rate on their pages, so their `cacheRead` is set equal to `input`
///     (no discount) rather than guessed.
///
/// The seeded entries are deliberately open-ended backwards: we never verified
/// what these models cost before that check, and inventing effective dates
/// would mis-price old sessions while looking authoritative. When a rate
/// changes, append a dated entry — costs before its `effectiveFrom` stay put.
public enum ModelPricing {
    /// Day the seeded Anthropic/Codex entries were checked against the
    /// pricing pages above.
    private static let seedVerification = "2026-07-02"
    /// Day the seeded OpenAI admin-usage-API entries (`openai-*` keys) were
    /// checked against their model pages (issue #554).
    private static let openAIVerification = "2026-09-08"

    private static let table: [String: PricingSchedule] = [
        "claude-sonnet": .constant(
            TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30),
            verifiedOn: seedVerification),
        "claude-opus": .constant(
            TokenPricing(input: 15.0, output: 75.0, cacheCreation: 18.75, cacheRead: 1.50),
            verifiedOn: seedVerification),
        "claude-haiku": .constant(
            TokenPricing(input: 0.25, output: 1.25, cacheCreation: 0.30, cacheRead: 0.03),
            verifiedOn: seedVerification),
        "claude-fable-5": .constant(
            TokenPricing(input: 10.0, output: 50.0, cacheCreation: 12.5, cacheRead: 1.0, cacheCreationOneHour: 20.0),
            verifiedOn: seedVerification),
        "claude-opus-4-8": .constant(
            TokenPricing(input: 5.0, output: 25.0, cacheCreation: 6.25, cacheRead: 0.50, cacheCreationOneHour: 10.0),
            verifiedOn: seedVerification),
        "claude-opus-4-7": .constant(
            TokenPricing(input: 5.0, output: 25.0, cacheCreation: 6.25, cacheRead: 0.50, cacheCreationOneHour: 10.0),
            verifiedOn: seedVerification),
        "claude-opus-4-6": .constant(
            TokenPricing(input: 5.0, output: 25.0, cacheCreation: 6.25, cacheRead: 0.50, cacheCreationOneHour: 10.0),
            verifiedOn: seedVerification),
        "claude-sonnet-4-6": .constant(
            TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30, cacheCreationOneHour: 6.0),
            verifiedOn: seedVerification),
        "claude-sonnet-4-5": .constant(
            TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30, cacheCreationOneHour: 6.0),
            verifiedOn: seedVerification),
        "claude-sonnet-4": .constant(
            TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30, cacheCreationOneHour: 6.0),
            verifiedOn: seedVerification),
        "claude-haiku-4-5": .constant(
            TokenPricing(input: 1.0, output: 5.0, cacheCreation: 1.25, cacheRead: 0.10, cacheCreationOneHour: 2.0),
            verifiedOn: seedVerification),
        "codex": .constant(
            TokenPricing(input: 1.25, output: 10.0, cacheCreation: 0, cacheRead: 0.125),
            verifiedOn: seedVerification),
        // Every published Codex slug currently bills at the base `codex` rate.
        // They are listed anyway so a future per-slug divergence is a one-line
        // table edit instead of re-plumbing the lookup.
        "gpt-5.6-sol": .constant(
            TokenPricing(input: 1.25, output: 10.0, cacheCreation: 0, cacheRead: 0.125),
            verifiedOn: seedVerification),
        "gpt-5.6-terra": .constant(
            TokenPricing(input: 1.25, output: 10.0, cacheCreation: 0, cacheRead: 0.125),
            verifiedOn: seedVerification),
        "gpt-5.6-luna": .constant(
            TokenPricing(input: 1.25, output: 10.0, cacheCreation: 0, cacheRead: 0.125),
            verifiedOn: seedVerification),
        "default": .constant(
            TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30),
            verifiedOn: seedVerification),
        // OpenAI admin-usage-API models (issue #554) — distinct keys from the
        // `codex`/`gpt-5.6-*` rows above, which price Codex CLI's own slugs,
        // not the raw model names the org usage API reports. OpenAI's usage
        // API has no cache-write charge, so `cacheCreation` is always 0.
        "openai-gpt-4o-mini": .constant(
            TokenPricing(input: 0.15, output: 0.60, cacheCreation: 0, cacheRead: 0.075),
            verifiedOn: openAIVerification),
        "openai-gpt-4o": .constant(
            TokenPricing(input: 2.50, output: 10.0, cacheCreation: 0, cacheRead: 1.25),
            verifiedOn: openAIVerification),
        "openai-gpt-4.1-mini": .constant(
            // Cached input is 75% off for the gpt-4.1 family, not the 50%
            // uniform discount the pre-#554 local table guessed.
            TokenPricing(input: 0.40, output: 1.60, cacheCreation: 0, cacheRead: 0.10),
            verifiedOn: openAIVerification),
        "openai-gpt-4.1": .constant(
            TokenPricing(input: 2.0, output: 8.0, cacheCreation: 0, cacheRead: 0.50),
            verifiedOn: openAIVerification),
        "openai-o1-mini": .constant(
            TokenPricing(input: 1.10, output: 4.40, cacheCreation: 0, cacheRead: 0.55),
            verifiedOn: openAIVerification),
        "openai-o1": .constant(
            TokenPricing(input: 15.0, output: 60.0, cacheCreation: 0, cacheRead: 7.5),
            verifiedOn: openAIVerification),
        "openai-o3-mini": .constant(
            TokenPricing(input: 1.10, output: 4.40, cacheCreation: 0, cacheRead: 0.55),
            verifiedOn: openAIVerification),
        "openai-gpt-4-turbo": .constant(
            // No cached-input tier on this model's pricing page — billed at
            // the full input rate rather than an invented discount.
            TokenPricing(input: 10.0, output: 30.0, cacheCreation: 0, cacheRead: 10.0),
            verifiedOn: openAIVerification),
        "openai-gpt-4": .constant(
            TokenPricing(input: 30.0, output: 60.0, cacheCreation: 0, cacheRead: 30.0),
            verifiedOn: openAIVerification),
        "openai-gpt-3.5": .constant(
            TokenPricing(input: 0.50, output: 1.50, cacheCreation: 0, cacheRead: 0.50),
            verifiedOn: openAIVerification),
        // Fallback for an OpenAI admin-usage model matching none of the keys
        // above — same rate the pre-#554 local table used as its default
        // (gpt-4o's rate, the family's long-standing flagship). `isKnownOpenAIModel`
        // is what actually drives the "unverified" marker shown to the user;
        // this row only keeps the estimate roughly in the right neighborhood.
        "openai-default": .constant(
            TokenPricing(input: 2.50, output: 10.0, cacheCreation: 0, cacheRead: 1.25),
            verifiedOn: openAIVerification)
    ]

    /// Verification dates of the shipped table itself — what the UI and CLI show
    /// before a scan has recorded which entries it actually used.
    public static let tableProvenance = PricingProvenance(
        verificationDates: table.values.flatMap { $0.entries.map(\.verifiedOn) }
    )

    /// Diagnostic seam for the cross-target contract test.
    public static var tableKeys: [String] { table.keys.sorted() }

    /// Diagnostic seam for the cross-target contract test.
    public static func schedule(forKey key: String) -> PricingSchedule? { table[key] }

    public static var codex: TokenPricing {
        codex(for: nil)
    }

    /// Per-model Codex rate at `timestamp`, falling back to the flat provider
    /// rate for slugs the table does not know yet.
    public static func codex(for model: String?, at timestamp: Date = Date()) -> TokenPricing {
        resolveCodex(for: model, at: timestamp).pricing
    }

    public static func resolveCodex(for model: String?, at timestamp: Date = Date()) -> ResolvedPricing {
        guard let model else { return resolve(key: "codex", at: timestamp) }
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return resolve(key: table[normalized] != nil ? normalized : "codex", at: timestamp)
    }

    public static func claude(for model: String?, at timestamp: Date = Date()) -> TokenPricing {
        resolveClaude(for: model, at: timestamp).pricing
    }

    public static func resolveClaude(for model: String?, at timestamp: Date = Date()) -> ResolvedPricing {
        resolve(key: claudeKey(for: model), at: timestamp)
    }

    public static func normalizeClaudeModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("anthropic.") {
            trimmed = String(trimmed.dropFirst("anthropic.".count))
        }
        if let lastDot = trimmed.lastIndex(of: "."), trimmed.contains("claude-") {
            let tail = String(trimmed[trimmed.index(after: lastDot)...])
            if tail.hasPrefix("claude-") { trimmed = tail }
        }
        if let versionRange = trimmed.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
            trimmed.removeSubrange(versionRange)
        }
        if let dateRange = trimmed.range(of: #"-\d{8}$"#, options: .regularExpression) {
            return String(trimmed[..<dateRange.lowerBound])
        }
        return trimmed
    }

    /// Model name → table key. Split out from the rate lookup so routing stays
    /// one decision and every key resolves through the same dated path.
    private static func claudeKey(for model: String?) -> String {
        guard let model else { return "claude-sonnet" }

        let normalized = normalizeClaudeModel(model)
        if table[normalized] != nil { return normalized }
        if normalized.contains("fable") { return "claude-fable-5" }
        if normalized.contains("opus") {
            if normalized.contains("4-8") { return "claude-opus-4-8" }
            if normalized.contains("4-7") { return "claude-opus-4-7" }
            if normalized.contains("4-6") { return "claude-opus-4-6" }
            return "claude-opus"
        }
        if normalized.contains("haiku") {
            return normalized.contains("4-5") ? "claude-haiku-4-5" : "claude-haiku"
        }
        if normalized.contains("sonnet") {
            if normalized.contains("4-6") { return "claude-sonnet-4-6" }
            if normalized.contains("4-5") { return "claude-sonnet-4-5" }
            if normalized.contains("4") { return "claude-sonnet-4" }
            return "claude-sonnet"
        }
        return "default"
    }

    // MARK: - OpenAI admin-usage-API models (issue #554)

    public static var openAI: TokenPricing {
        openAI(for: nil)
    }

    /// Per-model OpenAI admin-usage-API rate at `timestamp`, falling back to
    /// `openai-default` for a model the table does not carry.
    public static func openAI(for model: String?, at timestamp: Date = Date()) -> TokenPricing {
        resolveOpenAI(for: model, at: timestamp).pricing
    }

    public static func resolveOpenAI(for model: String?, at timestamp: Date = Date()) -> ResolvedPricing {
        resolve(key: openAIKey(for: model) ?? "openai-default", at: timestamp)
    }

    /// `true` when `model` matched a specific `openai-*` entry rather than
    /// falling through to `openai-default` — the signal `ApiUsagePricing`
    /// surfaces to the UI as unverified pricing, mirroring the Anthropic path.
    public static func isKnownOpenAIModel(_ model: String?) -> Bool {
        openAIKey(for: model) != nil
    }

    /// Trims, lowercases, and strips a trailing dated-snapshot suffix (e.g.
    /// `-2024-08-06`, `-0613`, `-0125`) so a versioned slug the usage API
    /// reports normalizes to the same key as its bare model name.
    public static func normalizeOpenAIModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let longDate = trimmed.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            trimmed.removeSubrange(longDate)
        } else if let shortDate = trimmed.range(of: #"-\d{4}$"#, options: .regularExpression) {
            trimmed.removeSubrange(shortDate)
        }
        return trimmed
    }

    /// Model name → table key, exact match only (issue #554). OpenAI's
    /// admin-usage-API model names are ambiguous under substring matching in
    /// list order — `"gpt-4"` is a prefix of `"gpt-4o"`, `"gpt-4.1"`, and
    /// `"gpt-4-turbo"` — the exact defect class that mispriced Anthropic's
    /// Opus 4 before #537. Every recognized slug is normalized, then looked
    /// up with `switch` equality; nothing here is matched with `.contains`.
    private static func openAIKey(for model: String?) -> String? {
        guard let model else { return nil }
        switch normalizeOpenAIModel(model) {
        case "gpt-4o-mini": return "openai-gpt-4o-mini"
        case "gpt-4o": return "openai-gpt-4o"
        case "gpt-4.1-mini": return "openai-gpt-4.1-mini"
        case "gpt-4.1": return "openai-gpt-4.1"
        case "o1-mini": return "openai-o1-mini"
        case "o1": return "openai-o1"
        case "o3-mini": return "openai-o3-mini"
        case "gpt-4-turbo": return "openai-gpt-4-turbo"
        case "gpt-4": return "openai-gpt-4"
        case "gpt-3.5-turbo", "gpt-3.5": return "openai-gpt-3.5"
        default: return nil
        }
    }

    private static func resolve(key: String, at timestamp: Date) -> ResolvedPricing {
        table[key]?.resolve(at: timestamp) ?? fallbackResolution
    }

    private static let fallbackResolution = ResolvedPricing(
        pricing: TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30),
        effectiveFrom: .distantPast,
        verifiedOn: seedVerification,
        precedesFirstEntry: false
    )
}
