import Foundation
import MeterBarShared

// MARK: - SocialLimitsCardContent

/// Content for the shareable quota card — the limits counterpart to
/// `SocialShareCardContent`.
///
/// Every label is lifted from the same properties the popover renders
/// (`UsageLimit.percentLeftText`, `UsagePace.leftLabel`,
/// `UsageLimit.resetCountdownText`, `QuotaBand.shortLabel`) rather than
/// recomputed, so a card someone posts cannot disagree with the app it was
/// taken from. Copy stays English like the token card: the artwork is a
/// bitmap for social, not a localized UI surface.
struct SocialLimitsCardContent: Equatable {
    // MARK: Lifecycle

    init(
        providerName: String,
        updatedText: String,
        headline: Row?,
        rows: [Row],
        generatedAt: Date = Date()
    ) {
        self.providerName = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.updatedText = updatedText
        self.headline = headline
        self.rows = rows
        self.generatedAt = generatedAt
    }

    /// Builds the card from the same presentation model the popover and
    /// dashboard cards read.
    init(snapshot: ProviderSnapshot, now: Date = Date(), generatedAt: Date = Date()) {
        let rows = Self.rows(for: snapshot, now: now)
        // `primaryLimit` already encodes the provider-blocking rule and Cursor's
        // spillover exception. A provider whose windows are all secondary still
        // deserves a hero, so fall back to the tightest row it does have.
        let headlineLimit = snapshot.primaryLimit.map { Self.row(for: $0, now: now) }
        self.init(
            providerName: snapshot.title,
            updatedText: snapshot.updatedText,
            headline: headlineLimit ?? rows.min { $0.percentLeft < $1.percentLeft },
            rows: rows,
            generatedAt: generatedAt
        )
    }

    // MARK: Internal

    /// Quota windows the card has room for. Providers with more windows keep
    /// the tightest ones — the rows that explain the headline.
    static let maxRowCount = 4

    let providerName: String
    let updatedText: String
    let headline: Row?
    let rows: [Row]
    let generatedAt: Date

    var hasQuotaData: Bool { headline != nil }

    /// Severity of the headline window, using the shared band thresholds.
    var band: QuotaBand? {
        headline.map { QuotaBand.forPercentLeft($0.percentLeft) }
    }

    var statusLabel: String { band?.shortLabel ?? "No data" }

    var quotaHeroValue: String {
        headline?.heroValueText ?? "NO QUOTA"
    }

    var quotaHeroCaption: String {
        guard let headline else { return "connect an account to see limits" }
        return "left on \(headline.title)"
    }

    var tier: SocialLimitsTier { SocialLimitsTier.classify(band: band) }

    var shareCaption: String {
        guard let headline else {
            return [
                "MeterBar isn't tracking any quota yet.",
                tier.joke,
                SocialShareCardContent.websiteURL,
            ].joined(separator: "\n")
        }
        let reset = headline.resetText.map { " Resets in \($0)." } ?? ""
        return [
            "\(headline.trailingText) on \(headline.title) — \(providerName).\(reset)",
            "\(tier.title): \(tier.joke)",
            SocialShareCardContent.websiteURL,
        ].joined(separator: "\n")
    }

    var defaultFilename: String {
        "meterbar-limits-card-\(SocialShareCardDateFormat.filename(generatedAt)).png"
    }

    /// Projects one quota window onto the card, honoring the popover's rule
    /// that a derived total must not drive a pace overlay.
    static func row(for limit: SnapshotLimit, now: Date = Date()) -> Row {
        let usageLimit = limit.usageLimit
        return Row(
            id: limit.id,
            title: limit.localizedTitle,
            percentLeft: limit.percentLeft,
            usedFraction: usageLimit.clampedUsed / usageLimit.clampedTotal,
            isEstimated: usageLimit.isEstimated,
            valueStyle: limit.valueStyle,
            remainingAmount: max(0, usageLimit.total - usageLimit.used),
            usedAmount: usageLimit.used,
            percentLeftText: usageLimit.percentLeftText,
            usedPercentText: usageLimit.usedPercentageText,
            pace: usageLimit.isEstimated ? nil : usageLimit.pace(now: now),
            resetText: usageLimit.resetCountdownText(now: now)
        )
    }

    static func rows(for snapshot: ProviderSnapshot, now: Date = Date()) -> [Row] {
        let rows = snapshot.limits.map { row(for: $0, now: now) }
        guard rows.count > maxRowCount else { return rows }
        // Trim by tightness but render in the provider's own order, so the card
        // reads like the popover it was taken from.
        let kept = Set(
            rows.sorted { $0.percentLeft < $1.percentLeft }
                .prefix(maxRowCount)
                .map(\.id)
        )
        return rows.filter { kept.contains($0.id) }
    }
}

// MARK: - SocialLimitsCardContent.Row

extension SocialLimitsCardContent {
    /// One quota window as the card draws it. Pure data — every branch
    /// (currency vs quota, out vs percent-left, estimated suppression) is
    /// testable without SwiftUI, mirroring `LimitRow.RowContent`.
    struct Row: Equatable, Identifiable {
        let id: String
        let title: String
        let percentLeft: Int
        /// `0...1` bar fill, from the clamped values the popover's bar uses.
        let usedFraction: Double
        let isEstimated: Bool
        let valueStyle: SnapshotLimit.ValueStyle
        let remainingAmount: Double
        let usedAmount: Double
        let percentLeftText: String
        let usedPercentText: String
        let pace: UsagePace?
        let resetText: String?

        private var isOut: Bool { percentLeft <= 0 }

        /// Matches `LimitRow.RowContent.trailingText`: an estimated total never
        /// gets to declare a quota "Out".
        var trailingText: String {
            switch valueStyle {
            case .currency:
                return "\(UsageFormat.cost(remainingAmount)) left"
            case .quota:
                return (isOut && !isEstimated) ? "Out" : percentLeftText
            }
        }

        var usedText: String {
            switch valueStyle {
            case .currency:
                return "\(UsageFormat.cost(usedAmount)) spent"
            case .quota:
                return usedPercentText
            }
        }

        /// The hero number, without the "left" suffix the row label carries.
        var heroValueText: String {
            switch valueStyle {
            case .currency:
                return UsageFormat.cost(remainingAmount)
            case .quota:
                return "\(isEstimated ? "~" : "")\(percentLeft)%"
            }
        }
    }
}

// MARK: - SocialLimitsTier

/// The card's punchline, keyed off the shared severity band so the joke and
/// the status badge can never contradict each other.
struct SocialLimitsTier: Equatable {
    let title: String
    let joke: String
    let symbolName: String

    static func classify(band: QuotaBand?) -> Self {
        guard let band else {
            return Self(
                title: "NO LIMITS TRACKED",
                joke: "Connect an account and find out how close you really are.",
                symbolName: "questionmark.folder.fill"
            )
        }
        switch band {
        case .healthy:
            return Self(
                title: "CRUISING",
                joke: "Plenty of quota left. Suspiciously little shipped.",
                symbolName: "checkmark.shield.fill"
            )
        case .tight:
            return Self(
                title: "RATIONING MODE",
                joke: "Every prompt is a budget decision now.",
                symbolName: "exclamationmark.triangle.fill"
            )
        case .critical:
            return Self(
                title: "LIVING ON FUMES",
                joke: "One more refactor and it's over.",
                symbolName: "exclamationmark.octagon.fill"
            )
        case .exhausted:
            return Self(
                title: "RATE LIMITED",
                joke: "Touched grass. Involuntarily.",
                symbolName: "hourglass.bottomhalf.filled"
            )
        }
    }
}
