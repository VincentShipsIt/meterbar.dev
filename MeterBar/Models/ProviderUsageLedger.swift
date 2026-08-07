import Foundation
import MeterBarShared

/// What a provider's running counter is denominated in.
///
/// Claude, Codex and Grok all write per-session logs with token counts and a
/// price, so their rows are dollars by construction. Cursor and OpenRouter
/// publish a single running scalar instead — and only one of the two is money.
/// The unit rides with every observation and every stored entry so a request
/// count can never be folded into a dollar total on the way to the chart.
nonisolated enum ProviderUsageUnit: String, Codable, Sendable {
    /// US dollars, as reported by the provider. Safe to fold into `costs[]`.
    case usd

    /// Requests or credits against a plan allowance. Cursor's usage-summary
    /// payload carries no currency field at all, so there is no rate to convert
    /// with — a dollar figure derived from this would be invented, not measured.
    case requests
}

/// One poll's reading of a provider's running counter.
///
/// Deliberately not a `UsageMetrics`: that type is serialized into the shared
/// app-group cache read by the widget and the CLI, and widening it to carry
/// accumulation state would drag two other codebases into this change for data
/// neither of them wants.
nonisolated struct ProviderUsageObservation: Sendable, Equatable {
    let provider: ServiceType
    let unit: ProviderUsageUnit

    /// The provider's counter as of `observedAt`. Lifetime for OpenRouter,
    /// current-billing-cycle for Cursor — the ledger does not care which, only
    /// that it moves monotonically until it resets.
    let runningTotal: Double

    /// The provider's own figure for the whole of `observedAt`'s calendar day,
    /// when it publishes one (OpenRouter's `usage_daily`). Authoritative for
    /// that day: it covers the hours MeterBar was not running, which a delta
    /// between two polls cannot.
    let authoritativeDailyTotal: Double?

    let observedAt: Date

    init(
        provider: ServiceType,
        unit: ProviderUsageUnit,
        runningTotal: Double,
        authoritativeDailyTotal: Double? = nil,
        observedAt: Date
    ) {
        self.provider = provider
        self.unit = unit
        self.runningTotal = runningTotal
        self.authoritativeDailyTotal = authoritativeDailyTotal
        self.observedAt = observedAt
    }
}

/// One day's accumulated contribution, in the entry's unit.
nonisolated struct ProviderUsageDay: Sendable, Equatable, Codable {
    let date: Date
    let amount: Double
}

/// Everything the ledger knows about one provider.
nonisolated struct ProviderUsageLedgerEntry: Codable, Sendable, Equatable {
    var provider: ServiceType
    var unit: ProviderUsageUnit

    /// The counter as of `lastObservedAt`, i.e. the baseline the next reading is
    /// differenced against.
    var lastObservedTotal: Double
    var lastObservedAt: Date

    /// The day of the first poll. Everything before it is genuinely unknown —
    /// MeterBar was not watching, and neither provider offers history to fill it
    /// in — so it bounds what the series is allowed to claim coverage of.
    var firstObservedOn: Date

    /// Day (start-of-day) to that day's accumulated amount.
    ///
    /// A day with no entry has no data *or* had nothing to report; a stored `0`
    /// would be a claim that the day was measured and empty, which is a stronger
    /// statement than the ledger can make. So zero is never written — see
    /// `ProviderUsageLedger.record`.
    var daily: [Date: Double]
}

/// A persisted poll-and-accumulate series for providers that keep no local log.
///
/// Cursor and OpenRouter both expose a running counter and nothing else: no
/// per-session records, no history endpoint, no dated breakdown to scan. The
/// only way either can appear in a dated series is for MeterBar to difference
/// that counter across its own polls, which is what this type does.
///
/// Two properties are load-bearing and easy to lose:
///
/// - **No backfill.** The series starts the day of the first poll. OpenRouter's
///   `usage` is a lifetime figure; treating the first reading as a delta against
///   zero would dump a year of history onto install day.
/// - **No zero rows.** A day is absent when nothing was observed for it. A
///   stored zero reads downstream as a measured, confirmed-empty day.
nonisolated struct ProviderUsageLedger: Codable, Sendable, Equatable {
    /// Bumped whenever the stored shape changes. A mismatch drops the artifact
    /// rather than migrating it — the cost is one lost baseline, and the series
    /// resumes from the next poll.
    static var currentSchemaVersion: Int { 1 }

    /// How much history the ledger keeps, in days.
    ///
    /// The file is rewritten on every successful poll for the life of the
    /// install, so an unbounded dictionary would grow forever and eventually
    /// trip the store's size guard — which fails the write, which freezes the
    /// baseline. 400 days comfortably covers the 30-day window the UI draws and
    /// the year-long activity calendar.
    static let retainedDays = 400

    var schemaVersion = ProviderUsageLedger.currentSchemaVersion

    /// The time zone the day buckets were computed in. Days are a local-calendar
    /// notion, so a ledger accumulated in one zone cannot be extended in another
    /// without silently mixing boundaries.
    var timeZoneIdentifier = TimeZone.current.identifier

    /// An array rather than a dictionary keyed by provider, matching
    /// `LifetimeCostSummary.providers`: the entry carries its own provider, and
    /// the JSON stays readable with a `ServiceType` raw value in it.
    var entries: [ProviderUsageLedgerEntry] = []

    init(entries: [ProviderUsageLedgerEntry] = []) {
        self.entries = entries
    }

    // MARK: - Reading

    func entry(for provider: ServiceType) -> ProviderUsageLedgerEntry? {
        entries.first { $0.provider == provider }
    }

    func unit(for provider: ServiceType) -> ProviderUsageUnit? {
        entry(for: provider)?.unit
    }

    /// The day of the first poll, or `nil` when the provider has never been
    /// observed. Callers use it to bound coverage rather than implying the
    /// series covers everything before it.
    func firstObservedDate(for provider: ServiceType) -> Date? {
        entry(for: provider)?.firstObservedOn
    }

    /// The provider's accumulated series, oldest first, in its own unit.
    func dailySeries(for provider: ServiceType) -> [ProviderUsageDay] {
        guard let entry = entry(for: provider) else { return [] }
        return entry.daily
            .map { ProviderUsageDay(date: $0.key, amount: $0.value) }
            .sorted { $0.date < $1.date }
    }

    /// The provider's series only when it is denominated in dollars.
    ///
    /// The single guard between a Cursor request count and `estimatedCostUSD`.
    /// Every caller that produces money goes through here.
    func dailyUSDSeries(for provider: ServiceType) -> [ProviderUsageDay] {
        guard entry(for: provider)?.unit == .usd else { return [] }
        return dailySeries(for: provider)
    }

    /// Providers whose series can honestly be reported as money, in a stable
    /// order so the folded `costs[]` rows don't reshuffle between refreshes.
    var usdProviders: [ServiceType] {
        entries.filter { $0.unit == .usd }
            .map(\.provider)
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// Providers whose series is a plan allowance rather than money.
    var nonUSDProviders: [ServiceType] {
        entries.filter { $0.unit != .usd }
            .map(\.provider)
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// Drops entries for providers the user has hidden, matching
    /// `CostSummary.filtered(to:)`.
    func filtered(to enabledServices: Set<ServiceType>) -> ProviderUsageLedger {
        ProviderUsageLedger(entries: entries.filter { enabledServices.contains($0.provider) })
    }

    // MARK: - Accumulating

    /// Folds one poll into the series.
    ///
    /// Silently ignores readings it cannot trust — a non-finite or negative
    /// counter, or one stamped earlier than the last reading recorded. Both are
    /// worse than useless if accepted: a `NaN` baseline makes every later
    /// comparison read as a reset, and a stale reading re-baselines downwards so
    /// that the next real poll charges the entire counter as one day's usage.
    mutating func record(_ observation: ProviderUsageObservation, calendar: Calendar = .current) {
        guard observation.runningTotal.isFinite, observation.runningTotal >= 0 else { return }

        let day = calendar.startOfDay(for: observation.observedAt)
        // A non-finite published total is dropped rather than stored: it would
        // propagate through every `reduce` downstream until the headline reads
        // "$nan".
        let authoritative = observation.authoritativeDailyTotal.flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        }

        guard let index = entries.firstIndex(where: { $0.provider == observation.provider }) else {
            entries.append(Self.makeEntry(from: observation, day: day, authoritative: authoritative))
            return
        }

        // A unit change means the counter now measures something else, so the
        // old baseline is not comparable. Restarting costs one poll interval;
        // differencing dollars against requests yields a number in neither unit.
        guard entries[index].unit == observation.unit else {
            entries[index] = Self.makeEntry(from: observation, day: day, authoritative: authoritative)
            return
        }

        guard observation.observedAt >= entries[index].lastObservedAt else { return }

        if let authoritative {
            // Sets the day absolutely — it replaces whatever the delta path had
            // accumulated, and is never added on top of this poll's own delta.
            entries[index].daily[day] = authoritative > 0 ? authoritative : nil
        } else {
            // A counter that dropped has reset (Cursor zeroes at
            // `billingCycleStart`), so the post-reset value *is* the new
            // contribution. Never `runningTotal - last`, which would be negative
            // and would cancel out spend already attributed to earlier days.
            let previous = entries[index].lastObservedTotal
            let delta = observation.runningTotal >= previous
                ? observation.runningTotal - previous
                : observation.runningTotal
            if delta > 0 {
                entries[index].daily[day, default: 0] += delta
            }
        }

        // Re-baseline on both paths. The published daily total is optional in
        // OpenRouter's payload, so the delta path can resume at any poll — and
        // it would resume against a stale baseline, re-charging everything since
        // the last non-authoritative reading.
        entries[index].lastObservedTotal = observation.runningTotal
        entries[index].lastObservedAt = observation.observedAt
        Self.prune(&entries[index], calendar: calendar)
    }

    /// The first entry for a provider: a baseline, and nothing more.
    ///
    /// The running counter is history the ledger has no right to date, so it is
    /// recorded as a starting point only. A published *daily* total is different
    /// — it claims today alone, so it is not backfill and is kept.
    private static func makeEntry(
        from observation: ProviderUsageObservation,
        day: Date,
        authoritative: Double?
    ) -> ProviderUsageLedgerEntry {
        var daily: [Date: Double] = [:]
        if let authoritative, authoritative > 0 {
            daily[day] = authoritative
        }
        return ProviderUsageLedgerEntry(
            provider: observation.provider,
            unit: observation.unit,
            lastObservedTotal: observation.runningTotal,
            lastObservedAt: observation.observedAt,
            firstObservedOn: day,
            daily: daily
        )
    }

    private static func prune(_ entry: inout ProviderUsageLedgerEntry, calendar: Calendar) {
        guard let newest = entry.daily.keys.max(),
              let cutoff = calendar.date(byAdding: .day, value: -retainedDays, to: newest) else { return }
        entry.daily = entry.daily.filter { $0.key >= cutoff }
        // Coverage cannot start earlier than the oldest day still retained,
        // otherwise the UI would draw a gap where data was pruned as if it were
        // a measured quiet stretch.
        entry.firstObservedOn = max(entry.firstObservedOn, cutoff)
    }
}
