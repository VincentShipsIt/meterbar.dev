import Foundation
import MeterBarShared

// MARK: - PublicProfileDocument

/// The whole of what the Public profile feature sends to meterbar.dev.
///
/// Every field is allowlisted by construction: the builder takes provider
/// display names, plan labels, quota window facts and the token receipt, and
/// nothing else. Account names are the trap. `ProviderSnapshot.title` carries
/// the user's own account label (often an email), so this type never reads it;
/// a provider is named from `ServiceType.displayName` and told apart from a
/// second account of the same provider by an ordinal.
///
/// The wire contract is `docs/public-profile-contract.md`. Bump `schemaVersion`
/// only for a breaking change; the site ignores fields it does not know.
nonisolated struct PublicProfileDocument: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    /// Days in `Receipt.dailyTokens`; the card's chart week.
    static let receiptDayCount = 7
    static let maxProviders = 12
    static let maxWindowsPerProvider = 6
    static let maxModels = 3

    struct Window: Codable, Equatable, Sendable {
        let label: String
        /// 0...100, from the same `percentLeft` the app's cards show.
        let usedPercent: Int
        /// Rounded to the minute so an unchanged window is an unchanged
        /// document, not a write every refresh.
        let resetsAt: Date?
        let pace: String?
    }

    struct Provider: Codable, Equatable, Sendable {
        /// `ServiceType.rawValue`, which the site maps to a logo and a color.
        let provider: String
        /// Display name plus an ordinal when a provider has several accounts.
        let name: String
        let plan: String?
        let windows: [Window]
    }

    struct Model: Codable, Equatable, Sendable {
        let provider: String
        let name: String
        let tokens: Int
    }

    struct Receipt: Codable, Equatable, Sendable {
        let tokens30d: Int
        let sessions: Int?
        let models: [Model]
        /// Oldest first, `receiptDayCount` entries, most recent day last.
        let dailyTokens: [Int]
    }

    var schema: Int
    var updatedAt: Date
    var providers: [Provider]
    var receipt: Receipt?

    var isEmpty: Bool { providers.isEmpty && receipt == nil }

    /// Same content, ignoring the timestamp: what "did anything change" means.
    func hasSameContent(as other: PublicProfileDocument) -> Bool {
        var lhs = self
        lhs.updatedAt = other.updatedAt
        return lhs == other
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    var jsonString: String {
        (try? encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: Building

    @MainActor
    static func make(
        snapshots: [ProviderSnapshot],
        plans: [ServiceType: String],
        costSummary: CostSummary?,
        now: Date = Date()
    ) -> PublicProfileDocument {
        let cards = snapshots.filter { $0.hasMetrics && !quotaLimits(of: $0).isEmpty }
        var seen: [ServiceType: Int] = [:]
        var providers: [Provider] = []
        for snapshot in cards.prefix(maxProviders) {
            let name: String
            switch snapshot.cardRole {
            case .account:
                let ordinal = (seen[snapshot.service] ?? 0) + 1
                seen[snapshot.service] = ordinal
                let total = cards.filter { $0.isAccountCard && $0.service == snapshot.service }.count
                name = total > 1
                    ? "\(snapshot.service.displayName) \(ordinal)"
                    : snapshot.service.displayName
            case .subPool:
                // A sub-pool's title is a product label ("Grok Bot"), never an
                // account name; the parent is named for the same reason the
                // share card names it.
                name = sanitizedLabel(snapshot.title).map { "\($0) on \(snapshot.service.displayName)" }
                    ?? snapshot.service.displayName
            }
            providers.append(
                Provider(
                    provider: snapshot.service.rawValue,
                    name: name,
                    plan: snapshot.isAccountCard ? plans[snapshot.service].flatMap(sanitizedPlan) : nil,
                    windows: quotaLimits(of: snapshot)
                        .prefix(maxWindowsPerProvider)
                        .compactMap { window(for: $0, now: now) }
                )
            )
        }

        return PublicProfileDocument(
            schema: schemaVersion,
            updatedAt: now,
            providers: providers,
            receipt: receipt(costSummary: costSummary, now: now)
        )
    }

    // MARK: Sanitizing

    /// Characters a label may carry. Provider window names ("Weekly", "Sonnet
    /// only", "Luna Reserve") fit; an email, a path or a URL does not, so a
    /// stray account string is dropped rather than published.
    private static let labelAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .+-&()%"
    )
    private static let modelAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    static func sanitizedLabel(_ raw: String, maxLength: Int = 40) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxLength,
              text.unicodeScalars.allSatisfy(labelAllowed.contains)
        else { return nil }
        return text
    }

    static func sanitizedPlan(_ raw: String) -> String? {
        sanitizedLabel(raw, maxLength: 24)
    }

    /// A model id is dropped, not trimmed, when it is not a plain identifier:
    /// fine-tune ids (`ft:gpt-4o:acme::abc`) carry an organization name.
    static func sanitizedModelName(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 48,
              text.unicodeScalars.allSatisfy(modelAllowed.contains)
        else { return nil }
        return text
    }

    // MARK: Private

    /// Quota windows only. A currency window is a dollar amount someone spent,
    /// which is not a limit and not what this profile is for.
    @MainActor
    private static func quotaLimits(of snapshot: ProviderSnapshot) -> [SnapshotLimit] {
        snapshot.limits.filter { $0.valueStyle == .quota }
    }

    @MainActor
    private static func window(for limit: SnapshotLimit, now: Date) -> Window? {
        guard let label = sanitizedLabel(limit.title) else { return nil }
        let row = SocialLimitsCardContent.row(for: limit, now: now)
        let reset = limit.usageLimit.resetTime.map {
            Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded() * 60)
        }
        return Window(
            label: label,
            usedPercent: min(100, max(0, 100 - row.percentLeft)),
            resetsAt: reset,
            pace: row.pace.flatMap { sanitizedLabel($0.leftLabel, maxLength: 32) }
        )
    }

    @MainActor
    private static func receipt(costSummary: CostSummary?, now: Date) -> Receipt? {
        guard let costSummary, costSummary.totalTokens > 0 else { return nil }
        let total = costSummary.totalTokens
        let content = SocialCardRenderer.content(
            costSummary: costSummary,
            providerSnapshotTitles: [],
            enabledSourceLabels: [],
            generatedAt: now
        )
        let models = content.modelSlices.compactMap { slice -> Model? in
            guard let name = sanitizedModelName(slice.name) else { return nil }
            return Model(provider: slice.provider.rawValue, name: name, tokens: max(0, slice.tokens))
        }
        var daily = content.dailyBurn.map { max(0, $0.tokens) }
        if daily.count < receiptDayCount {
            daily = Array(repeating: 0, count: receiptDayCount - daily.count) + daily
        }
        return Receipt(
            tokens30d: max(0, total),
            sessions: content.sessionCount,
            models: Array(models.prefix(maxModels)),
            dailyTokens: Array(daily.suffix(receiptDayCount))
        )
    }
}
