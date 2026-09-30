import MeterBarShared
import SwiftUI

/// The ranked "what should I use next?" card, at the top of the Limits page.
///
/// This is quota data, not cost data, so it lives with the quota cards it is
/// ranked from rather than on the Usage page (issue #593); the Overview page
/// keeps its own one-line tile of the same ranking.
///
/// It reads the quota snapshots the app already refreshes, so it answers the
/// question before a single token log has been scanned. Ticks on the shared
/// reset-countdown schedule so the countdowns, and the ranking that weighs
/// them, stay current without a clock of its own.
struct HeadroomRecommendationCard: View {
    /// Every enabled provider/account, *unfiltered* — the card needs the ones
    /// without cached usage so it can list them as "no data" instead of quietly
    /// dropping them.
    let providerSnapshots: [ProviderSnapshot]

    var body: some View {
        TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
            let recommendation = providerSnapshots.headroomRecommendation(now: timeline.date)
            if !recommendation.rows.isEmpty || !recommendation.unavailable.isEmpty {
                DashboardCard(title: "What To Use Next", trailing: Self.caption(for: recommendation)) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let headline = recommendation.headline {
                            Text(headline)
                                .font(.callout)
                                .fontWeight(.semibold)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        ForEach(Array(recommendation.rows.enumerated()), id: \.element.id) { index, row in
                            HeadroomRecommendationRow(rank: index + 1, row: row)
                        }

                        if !recommendation.unavailable.isEmpty {
                            Divider()
                            // Named, not hidden: a provider MeterBar cannot read is a fact the
                            // user needs, and guessing a rank for it would be worse than
                            // saying nothing.
                            Text("No data")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                            ForEach(recommendation.unavailable) { entry in
                                HeadroomUnavailableRow(entry: entry)
                            }
                        }

                        Divider()

                        Label(
                            "Ranked on your Mac from quota data MeterBar already caches — no extra requests, "
                                + "and nothing switches tools for you.",
                            systemImage: "lock.shield"
                        )
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    /// Card caption. Names the state instead of restating the headline.
    ///
    /// Internal (not private) so the wording can be asserted without hosting the
    /// page, matching `DashboardStatusSection.refreshButtonTitle(isRefreshing:)`.
    static func caption(for recommendation: ProviderRecommendation) -> String {
        if recommendation.isEmpty { return "No usable data" }
        if recommendation.isFullyExhausted { return "Every window spent" }
        return "Ranked by remaining headroom"
    }
}

/// One row of the "what to use next" ranking.
///
/// Every value on the row is an input to its score — binding window, percent
/// left, reset countdown, pace — so the ordering can be read off the row rather
/// than taken on faith. Deliberately plain: this is arithmetic over cached
/// quota numbers, not a prediction.
struct HeadroomRecommendationRow: View {
    struct Content: Equatable {
        let statusBand: QuotaBand
        let windowText: String
        let valueText: String?
        let footerParts: [String]

        init(row: ProviderRecommendationRow) {
            statusBand = row.band
            windowText = row.windowTitle
            if row.isExhausted {
                valueText = nil
                footerParts = [row.availabilityText].compactMap { $0 }
            } else {
                valueText = row.headroomText
                footerParts = [row.resetText, row.paceText].compactMap { $0 }
            }
        }

        var showsUsage: Bool { valueText != nil }
    }

    let rank: Int
    let row: ProviderRecommendationRow

    var content: Content { Content(row: row) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("\(rank)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .frame(width: 14, alignment: .trailing)

                Circle()
                    .fill(MeterBarTheme.accent(for: row.service))
                    .frame(width: 8, height: 8)

                Text(row.name)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                ProviderCardStatusLabel(band: content.statusBand)
            }

            if content.showsUsage {
                HStack(spacing: 8) {
                    Text(content.windowText)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    Spacer(minLength: 8)

                    if let valueText = content.valueText {
                        Text(valueText)
                            .font(.callout)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                }

                HeadroomShareBar(
                    fraction: Double(row.percentLeft) / 100,
                    tint: MeterBarTheme.accent(for: row.service)
                )
            }

            let supportingParts = content.showsUsage
                ? content.footerParts
                : [content.windowText] + content.footerParts
            if !supportingParts.isEmpty {
                Text(supportingParts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rank \(rank)")
        .accessibilityValue(row.summary)
    }
}

/// A provider left out of the ranking, with the reason in place of a rank.
private struct HeadroomUnavailableRow: View {
    let entry: ProviderRecommendationUnavailableRow

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(MeterBarTheme.accent(for: entry.service))
                .frame(width: 8, height: 8)

            Text(entry.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text(entry.detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.name)
        .accessibilityValue(entry.detail)
    }
}

private struct HeadroomShareBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 4)
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, proxy.size.width * clampedFraction), height: 4)
            }
        }
        .frame(height: 4)
    }

    private var clampedFraction: CGFloat {
        CGFloat(min(1, max(0, fraction)))
    }
}
