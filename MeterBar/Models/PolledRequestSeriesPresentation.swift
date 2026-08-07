import Foundation
import MeterBarShared

/// The view-facing shape of every polled series that is *not* denominated in
/// dollars.
///
/// `ProviderUsageCostBuilder` bars these from `costs[]` and `dailyUsage[]`,
/// because those arrays carry `estimatedCostUSD` and a request count is not
/// money — Cursor's `/api/usage-summary` publishes no currency field and no
/// per-request rate, so any dollar figure derived from it would be invented.
/// Dropping the series entirely would trade one wrong number for no number,
/// so it surfaces here instead, labelled in the unit it was measured in.
///
/// Mirrors `CostChartPresentation`: a value type computed from the model, with
/// all windowing and ordering resolved before the view sees it.
nonisolated struct PolledRequestSeriesPresentation: Sendable, Equatable {
    static let defaultRequestedDays = 30

    /// One provider's windowed series.
    nonisolated struct ProviderSeries: Sendable, Equatable {
        let provider: ServiceType
        let unit: ProviderUsageUnit

        /// Days inside the window that carry a measured amount, oldest first.
        ///
        /// Never padded: a day the ledger has no entry for is a day MeterBar did
        /// not measure, and a zero-amount bar would claim it measured one and
        /// found nothing.
        let days: [ProviderUsageDay]

        /// The window's total, summed from `days` alone.
        let total: Double

        /// The day of the first successful poll.
        ///
        /// The series cannot reach back past it — neither provider serves dated
        /// history — so the view states it rather than letting the empty stretch
        /// before it read as measured inactivity.
        let trackingStartedOn: Date

        /// True when the provider has been polled but no increase has yet been
        /// observed inside the window.
        var hasNoMeasuredDays: Bool { days.isEmpty }

        /// The window total with its unit spelled out, e.g. "1,204 requests".
        ///
        /// The unit is written into the string rather than left to the caller,
        /// because the label is the last place it can be lost: a user reads
        /// "$1,204", not `ProviderUsageUnit.requests`.
        var formattedTotal: String {
            let rounded = Int(total.rounded())
            switch unit {
            case .usd:
                return UsageFormat.cost(total)
            case .requests:
                return "\(UsageFormat.groupedTokens(rounded)) \(rounded == 1 ? "request" : "requests")"
            }
        }
    }

    let requestedDays: Int
    let providers: [ProviderSeries]

    var isEmpty: Bool { providers.isEmpty }

    init(
        ledger: ProviderUsageLedger,
        requestedDays: Int = PolledRequestSeriesPresentation.defaultRequestedDays,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let normalizedDays = max(1, requestedDays)
        let today = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -(normalizedDays - 1), to: today) ?? today

        self.requestedDays = normalizedDays
        // `nonUSDProviders` is already sorted by raw value, so the card order is
        // stable across refreshes instead of following dictionary iteration.
        providers = ledger.nonUSDProviders.compactMap { provider in
            guard let unit = ledger.unit(for: provider),
                  let trackingStartedOn = ledger.firstObservedDate(for: provider) else {
                return nil
            }
            // Future-dated days are dropped rather than clamped: a backwards
            // clock jump should lose one bar, not move it onto a day it did not
            // happen.
            let days = ledger.dailySeries(for: provider).filter { day in
                day.amount > 0 && day.date >= windowStart && day.date <= today
            }
            return ProviderSeries(
                provider: provider,
                unit: unit,
                days: days,
                total: days.reduce(0) { $0 + $1.amount },
                trackingStartedOn: trackingStartedOn
            )
        }
    }
}
