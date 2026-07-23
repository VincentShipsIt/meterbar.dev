import Foundation
import MeterBarShared

/// Pure, deterministic chart input derived from one reviewed `CostSummary`.
///
/// Coverage policy:
/// - The chart always represents the most recent `requestedDays` calendar days,
///   ordered oldest to newest.
/// - Days inside the cache's demonstrated span with no rows are confirmed as
///   zero spend.
/// - Days before that span are uncovered gaps, not synthetic zero values.
nonisolated struct CostChartPresentation: Sendable {
    static let defaultRequestedDays = 30
    private static let reconciliationToleranceUSD = 0.005

    let requestedDays: Int
    let coveredDays: Int
    let startDate: Date
    let endDate: Date
    let chartDomainEndDate: Date
    let modelWindowDays: Int
    let dailyBuckets: [CostDailyBucket]
    let dailyProviderPoints: [CostDailyProviderPoint]
    let modelPoints: [CostModelSpendPoint]
    let selectedPeriodTotalUSD: Double
    let dailyTotalUSD: Double
    let modelTotalUSD: Double
    let hasUnattributedModelSpend: Bool

    init(
        summary: CostSummary,
        requestedDays: Int = CostChartPresentation.defaultRequestedDays,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let normalizedDays = max(1, requestedDays)
        let today = calendar.startOfDay(for: now)
        let startDate = CostTracker.costWindowStart(
            days: normalizedDays,
            now: now,
            calendar: calendar
        )
        let windowRows = summary.dailyUsage.filter { row in
            let day = calendar.startOfDay(for: row.date)
            return day >= startDate && day <= today
        }
        let costWindow = summary.dailyCostWindow(
            lastDays: normalizedDays,
            now: now,
            calendar: calendar
        )
        let coverageStart = costWindow.coveredDays > 0
            ? calendar.date(byAdding: .day, value: -(costWindow.coveredDays - 1), to: today)
            : nil

        let rowsByDay = Dictionary(grouping: windowRows) { row in
            calendar.startOfDay(for: row.date)
        }
        dailyBuckets = (0..<normalizedDays).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }
            let isCovered = coverageStart.map { date >= $0 } ?? false
            let costUSD = isCovered
                ? rowsByDay[date, default: []].reduce(0) { $0 + max(0, $1.estimatedCostUSD) }
                : nil
            return CostDailyBucket(date: date, costUSD: costUSD)
        }

        var dailyTotals: [CostDailyProviderKey: Double] = [:]
        for row in windowRows {
            let key = CostDailyProviderKey(
                date: calendar.startOfDay(for: row.date),
                provider: row.provider
            )
            dailyTotals[key, default: 0] += max(0, row.estimatedCostUSD)
        }
        dailyProviderPoints = dailyTotals
            .compactMap { key, costUSD in
                guard costUSD > 0 else { return nil }
                return CostDailyProviderPoint(
                    date: key.date,
                    provider: key.provider,
                    costUSD: costUSD
                )
            }
            .sorted {
                if $0.date == $1.date {
                    return $0.provider.rawValue < $1.provider.rawValue
                }
                return $0.date < $1.date
            }

        let modelResult = Self.makeModelPoints(from: summary.costs)
        modelPoints = modelResult.points
        hasUnattributedModelSpend = modelResult.hasUnattributed

        self.requestedDays = normalizedDays
        coveredDays = costWindow.coveredDays
        self.startDate = startDate
        endDate = today
        chartDomainEndDate = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        modelWindowDays = max(0, summary.periodDays)
        selectedPeriodTotalUSD = max(0, summary.totalCostUSD)
        dailyTotalUSD = windowRows.reduce(0) { $0 + max(0, $1.estimatedCostUSD) }
        modelTotalUSD = modelPoints.reduce(0) { $0 + $1.costUSD }
    }

    var zeroSpendDays: [CostDailyBucket] {
        dailyBuckets.filter { $0.costUSD == 0 }
    }

    var hasSpend: Bool {
        selectedPeriodTotalUSD > 0 || dailyTotalUSD > 0 || modelTotalUSD > 0
    }

    var hasDailyCoverage: Bool {
        coveredDays > 0
    }

    var isDailyCoveragePartial: Bool {
        coveredDays < requestedDays
    }

    var modelTotalReconciles: Bool {
        abs(modelTotalUSD - selectedPeriodTotalUSD) <= Self.reconciliationToleranceUSD
    }

    var modelWindowMatchesRequested: Bool {
        modelWindowDays == requestedDays
    }

    private static func makeModelPoints(
        from costs: [TokenCost]
    ) -> (points: [CostModelSpendPoint], hasUnattributed: Bool) {
        var totals: [CostModelKey: Double] = [:]
        var hasUnattributed = false

        for cost in costs {
            let providerTotal = max(0, cost.estimatedCostUSD)
            let attributedTotal = cost.modelBreakdowns.reduce(0) { result, breakdown in
                let amount = max(0, breakdown.estimatedCostUSD)
                guard amount > 0 else { return result }
                let key = CostModelKey(provider: cost.provider, name: breakdown.name)
                totals[key, default: 0] += amount
                return result + amount
            }
            let unattributed = providerTotal - attributedTotal
            if unattributed > Self.reconciliationToleranceUSD {
                totals[CostModelKey(provider: cost.provider, name: "Unattributed"), default: 0] += unattributed
                hasUnattributed = true
            }
        }

        let rawPoints = totals
            .compactMap { key, costUSD -> CostModelSpendPoint? in
                guard costUSD > 0 else { return nil }
                return CostModelSpendPoint(
                    provider: key.provider,
                    model: key.name,
                    chartLabel: key.name,
                    costUSD: costUSD
                )
            }
            .sorted {
                if $0.costUSD == $1.costUSD {
                    if $0.model == $1.model {
                        return $0.provider.rawValue < $1.provider.rawValue
                    }
                    return $0.model < $1.model
                }
                return $0.costUSD > $1.costUSD
            }

        let duplicateNames = Dictionary(grouping: rawPoints, by: \.model)
        let points = rawPoints.map { point in
            let label = duplicateNames[point.model, default: []].count > 1
                ? "\(point.model) · \(point.provider.displayName)"
                : point.model
            return CostModelSpendPoint(
                provider: point.provider,
                model: point.model,
                chartLabel: label,
                costUSD: point.costUSD
            )
        }
        return (points, hasUnattributed)
    }
}

nonisolated struct CostDailyBucket: Identifiable, Sendable {
    var id: Date { date }

    let date: Date
    /// `nil` means the cache does not cover this date; `0` is a covered zero-spend day.
    let costUSD: Double?
}

nonisolated struct CostDailyProviderPoint: Identifiable, Sendable {
    var id: String {
        "\(date.timeIntervalSinceReferenceDate)-\(provider.rawValue)"
    }

    let date: Date
    let provider: ServiceType
    let costUSD: Double
}

nonisolated struct CostModelSpendPoint: Identifiable, Sendable {
    var id: String { "\(provider.rawValue)-\(model)" }

    let provider: ServiceType
    let model: String
    let chartLabel: String
    let costUSD: Double
}

nonisolated private struct CostDailyProviderKey: Hashable, Sendable {
    let date: Date
    let provider: ServiceType
}

nonisolated private struct CostModelKey: Hashable, Sendable {
    let provider: ServiceType
    let name: String
}
