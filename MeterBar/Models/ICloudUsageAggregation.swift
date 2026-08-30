import Foundation
import MeterBarShared

/// A MeterBar installation registered in the user's private CloudKit database.
/// The UUID is generated once and also names the installation's record zone.
nonisolated struct ICloudUsageDevice: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1

    let id: UUID
    let name: String
    let lastSeenAt: Date
}

/// One coarse quota window. No credential, raw response, or log content is
/// represented by this wire type.
nonisolated struct ICloudQuotaWindow: Codable, Equatable, Sendable {
    let kind: String
    let used: Double
    let total: Double
    let resetAt: Date?
}

/// Provider/account quota state captured at refresh cadence. Account identity
/// is the dedupe key: shared server-side quota is selected once, never summed
/// merely because two Macs observed it.
nonisolated struct ICloudQuotaSnapshot: Codable, Equatable, Sendable {
    let provider: ServiceType
    let accountIdentity: String
    let capturedAt: Date
    let windows: [ICloudQuotaWindow]

    init(
        provider: ServiceType,
        accountIdentity: String,
        capturedAt: Date,
        windows: [ICloudQuotaWindow]
    ) {
        self.provider = provider
        self.accountIdentity = accountIdentity
        self.capturedAt = capturedAt
        self.windows = windows
    }

    @MainActor
    init?(snapshot: ProviderSnapshot, externalAccountIdentity: String?) {
        guard snapshot.isAccountCard,
              let capturedAt = snapshot.updatedAt,
              !snapshot.limits.isEmpty,
              let accountIdentity = Self.accountIdentity(
                  provider: snapshot.service,
                  externalAccountIdentity: externalAccountIdentity
              ) else {
            return nil
        }
        provider = snapshot.service
        self.accountIdentity = accountIdentity
        self.capturedAt = capturedAt
        windows = snapshot.limits.map {
            ICloudQuotaWindow(
                kind: $0.id,
                used: $0.usageLimit.used,
                total: $0.usageLimit.total,
                resetAt: $0.usageLimit.resetTime
            )
        }
    }

    init?(metrics: UsageMetrics, externalAccountIdentity: String?) {
        guard let accountIdentity = Self.accountIdentity(
            provider: metrics.service,
            externalAccountIdentity: externalAccountIdentity
        ) else {
            return nil
        }
        let candidates: [(String, UsageLimit?)] = [
            ("session", metrics.sessionLimit),
            ("weekly", metrics.weeklyLimit),
            ("codeReview", metrics.codeReviewLimit),
        ] + metrics.additionalLimits.enumerated().map { index, limit in
            ("additional-\(index)-\(limit.periodKind?.rawValue ?? "unknown")", limit)
        }
        let windows = candidates.compactMap { kind, limit -> ICloudQuotaWindow? in
            guard let limit else { return nil }
            return ICloudQuotaWindow(
                kind: kind,
                used: limit.used,
                total: limit.total,
                resetAt: limit.resetTime
            )
        }
        guard !windows.isEmpty else { return nil }

        provider = metrics.service
        self.accountIdentity = accountIdentity
        capturedAt = metrics.lastUpdated
        self.windows = windows
    }

    private static func accountIdentity(
        provider: ServiceType,
        externalAccountIdentity: String?
    ) -> String? {
        guard let normalized = externalAccountIdentity?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !normalized.isEmpty,
            normalized.utf8.count <= 256,
            normalized.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return "\(provider.rawValue):\(normalized)"
    }
}

/// The only usage payload uploaded by MeterBar: one provider on one calendar
/// day for one installation. Attribution arrays and raw session/log fields do
/// not exist in this schema by design.
nonisolated struct ICloudDailyUsageRollup: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let deviceID: UUID
    let provider: ServiceType
    let day: Date
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let estimatedCostUSD: Double
    let quotaSnapshots: [ICloudQuotaSnapshot]
    let updatedAt: Date

    var totalTokens: Int {
        max(0, inputTokens) + max(0, outputTokens) + max(0, cacheCreationTokens) + max(0, cacheReadTokens)
    }

    init(
        deviceID: UUID,
        provider: ServiceType,
        day: Date,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int,
        estimatedCostUSD: Double,
        quotaSnapshots: [ICloudQuotaSnapshot],
        updatedAt: Date
    ) {
        self.deviceID = deviceID
        self.provider = provider
        self.day = day
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.quotaSnapshots = quotaSnapshots
        self.updatedAt = updatedAt
    }

    var recordName: String {
        let epochDay = Int(day.timeIntervalSince1970 / 86_400)
        return "rollup-\(provider.rawValue)-\(epochDay)"
    }
}

/// Explicit, reviewable CloudKit payload contract. Production writes exactly
/// these fields and tests reject any accidental attribution/secret expansion.
nonisolated enum ICloudUsageRecordSchema {
    static let deviceRecordType = "MeterBarDeviceV1"
    static let rollupRecordType = "MeterBarDailyUsageV1"

    static let deviceFieldNames: Set<String> = [
        "schemaVersion", "deviceID", "deviceName", "lastSeenAt",
    ]
    static let rollupFieldNames: Set<String> = [
        "schemaVersion", "deviceID", "provider", "day", "inputTokens",
        "outputTokens", "cacheCreationTokens", "cacheReadTokens", "estimatedCostUSD",
        "quotaSnapshots", "updatedAt",
    ]

    static func fields(for device: ICloudUsageDevice) -> [String: Any] {
        [
            "schemaVersion": ICloudUsageDevice.schemaVersion,
            "deviceID": device.id.uuidString,
            "deviceName": device.name,
            "lastSeenAt": device.lastSeenAt,
        ]
    }

    static func fields(for rollup: ICloudDailyUsageRollup) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return [
            "schemaVersion": ICloudDailyUsageRollup.schemaVersion,
            "deviceID": rollup.deviceID.uuidString,
            "provider": rollup.provider.rawValue,
            "day": rollup.day,
            "inputTokens": max(0, rollup.inputTokens),
            "outputTokens": max(0, rollup.outputTokens),
            "cacheCreationTokens": max(0, rollup.cacheCreationTokens),
            "cacheReadTokens": max(0, rollup.cacheReadTokens),
            "estimatedCostUSD": max(0, rollup.estimatedCostUSD),
            "quotaSnapshots": try encoder.encode(rollup.quotaSnapshots),
            "updatedAt": rollup.updatedAt,
        ]
    }
}

nonisolated struct ICloudUsageRepositorySnapshot: Sendable {
    let devices: [ICloudUsageDevice]
    let rollups: [ICloudDailyUsageRollup]
}

nonisolated protocol ICloudUsageRepository: Sendable {
    func synchronize(
        device: ICloudUsageDevice,
        rollups: [ICloudDailyUsageRollup]
    ) async throws -> ICloudUsageRepositorySnapshot

    func removeDevice(id: UUID) async throws
}

nonisolated struct ICloudUsageAggregationResult: Sendable {
    let devices: [ICloudUsageDevice]
    let activeDevices: [ICloudUsageDevice]
    let quotaSnapshots: [ICloudQuotaSnapshot]
    let costSummary: CostSummary
    let contributingDeviceIDs: [UUID]
    let contributingDeviceIDsByProvider: [ServiceType: [UUID]]
    let rollups: [ICloudDailyUsageRollup]

    var totalTokens: Int { costSummary.totalTokens }
    var totalCostUSD: Double { costSummary.totalCostUSD }

    func contributingDevices(for provider: ServiceType) -> [ICloudUsageDevice] {
        let ids = Set(contributingDeviceIDsByProvider[provider] ?? [])
        return devices.filter { ids.contains($0.id) }
    }

    func contributingDevices(
        for provider: ServiceType,
        startingAt startDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ICloudUsageDevice] {
        let today = calendar.startOfDay(for: now)
        let start = calendar.startOfDay(for: startDate)
        let ids = Set(rollups.compactMap { rollup -> UUID? in
            let day = calendar.startOfDay(for: rollup.day)
            guard rollup.provider == provider,
                  day >= start,
                  day <= today,
                  rollup.totalTokens > 0 || rollup.estimatedCostUSD > 0 else {
                return nil
            }
            return rollup.deviceID
        })
        return devices.filter { ids.contains($0.id) }
    }
}

/// Pure last-writer-wins merge and multi-device fold. CloudKit transport and
/// UI state deliberately stay outside this type so every conflict rule runs
/// offline in unit tests.
nonisolated enum ICloudUsageAggregation {
    static let activeDeviceInterval: TimeInterval = 14 * 24 * 60 * 60
    static let visibleDayCount = 30

    private struct RollupKey: Hashable {
        let deviceID: UUID
        let provider: ServiceType
        let day: Date
    }

    private struct QuotaKey: Hashable {
        let provider: ServiceType
        let accountIdentity: String
    }

    static func fold(
        devices: [ICloudUsageDevice],
        rollups: [ICloudDailyUsageRollup],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ICloudUsageAggregationResult {
        var catalog: [UUID: ICloudUsageDevice] = [:]
        for device in devices {
            guard let existing = catalog[device.id] else {
                catalog[device.id] = device
                continue
            }
            if device.lastSeenAt > existing.lastSeenAt
                || (device.lastSeenAt == existing.lastSeenAt && device.name > existing.name) {
                catalog[device.id] = device
            }
        }
        let knownDeviceIDs = Set(catalog.keys)
        var winners: [RollupKey: ICloudDailyUsageRollup] = [:]

        for rollup in rollups where knownDeviceIDs.contains(rollup.deviceID) {
            let key = RollupKey(
                deviceID: rollup.deviceID,
                provider: rollup.provider,
                day: calendar.startOfDay(for: rollup.day)
            )
            guard let existing = winners[key] else {
                winners[key] = rollup
                continue
            }
            if rollup.updatedAt > existing.updatedAt
                || (rollup.updatedAt == existing.updatedAt && stableTieBreak(rollup) > stableTieBreak(existing)) {
                winners[key] = rollup
            }
        }

        let selected = Array(winners.values)
        let today = calendar.startOfDay(for: now)
        let visibleCutoff = calendar.date(
            byAdding: .day,
            value: -(visibleDayCount - 1),
            to: today
        ) ?? today
        let visible = selected.filter {
            let day = calendar.startOfDay(for: $0.day)
            return day >= visibleCutoff && day <= today
        }
        var quotaWinners: [QuotaKey: ICloudQuotaSnapshot] = [:]
        for snapshot in selected.flatMap(\.quotaSnapshots) {
            let key = QuotaKey(provider: snapshot.provider, accountIdentity: snapshot.accountIdentity)
            if quotaWinners[key].map({ snapshot.capturedAt > $0.capturedAt }) ?? true {
                quotaWinners[key] = snapshot
            }
        }

        let sortedDevices = catalog.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let activeCutoff = now.addingTimeInterval(-activeDeviceInterval)
        let activeDevices = sortedDevices.filter { $0.lastSeenAt >= activeCutoff }
        let contributingRows = visible.filter { $0.totalTokens > 0 || $0.estimatedCostUSD > 0 }
        let contributorIDs = Set(contributingRows.map(\.deviceID))
        let byProvider = Dictionary(grouping: contributingRows, by: \.provider).mapValues { rows in
            Array(Set(rows.map(\.deviceID))).sorted { $0.uuidString < $1.uuidString }
        }

        return ICloudUsageAggregationResult(
            devices: sortedDevices,
            activeDevices: activeDevices,
            quotaSnapshots: quotaWinners.values.sorted {
                if $0.provider.sortOrder != $1.provider.sortOrder {
                    return $0.provider.sortOrder < $1.provider.sortOrder
                }
                return $0.accountIdentity < $1.accountIdentity
            },
            costSummary: makeCostSummary(from: visible, calendar: calendar),
            contributingDeviceIDs: contributorIDs.sorted { $0.uuidString < $1.uuidString },
            contributingDeviceIDsByProvider: byProvider,
            rollups: selected
        )
    }

    static func localRollups(
        deviceID: UUID,
        summary: CostSummary?,
        quotaSnapshots: [ICloudQuotaSnapshot],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ICloudDailyUsageRollup] {
        var rows: [String: ICloudDailyUsageRollup] = [:]
        for usage in summary?.dailyUsage ?? [] {
            let day = calendar.startOfDay(for: usage.date)
            let key = "\(usage.provider.rawValue):\(day.timeIntervalSinceReferenceDate)"
            rows[key] = ICloudDailyUsageRollup(
                deviceID: deviceID,
                provider: usage.provider,
                day: day,
                inputTokens: max(0, usage.inputTokens),
                outputTokens: max(0, usage.outputTokens),
                cacheCreationTokens: max(0, usage.cacheCreationTokens),
                cacheReadTokens: max(0, usage.cacheReadTokens),
                estimatedCostUSD: max(0, usage.estimatedCostUSD),
                quotaSnapshots: [],
                updatedAt: now
            )
        }

        let today = calendar.startOfDay(for: now)
        for (provider, snapshots) in Dictionary(grouping: quotaSnapshots, by: \.provider) {
            let key = "\(provider.rawValue):\(today.timeIntervalSinceReferenceDate)"
            if let existing = rows[key] {
                rows[key] = ICloudDailyUsageRollup(
                    deviceID: existing.deviceID,
                    provider: existing.provider,
                    day: existing.day,
                    inputTokens: existing.inputTokens,
                    outputTokens: existing.outputTokens,
                    cacheCreationTokens: existing.cacheCreationTokens,
                    cacheReadTokens: existing.cacheReadTokens,
                    estimatedCostUSD: existing.estimatedCostUSD,
                    quotaSnapshots: snapshots,
                    updatedAt: now
                )
            } else {
                rows[key] = ICloudDailyUsageRollup(
                    deviceID: deviceID,
                    provider: provider,
                    day: today,
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheCreationTokens: 0,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 0,
                    quotaSnapshots: snapshots,
                    updatedAt: now
                )
            }
        }

        return rows.values.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            return $0.provider.sortOrder < $1.provider.sortOrder
        }
    }

    private static func makeCostSummary(
        from rollups: [ICloudDailyUsageRollup],
        calendar: Calendar
    ) -> CostSummary {
        struct DailyKey: Hashable {
            let provider: ServiceType
            let day: Date
        }
        let dailyGroups = Dictionary(grouping: rollups) {
            DailyKey(provider: $0.provider, day: calendar.startOfDay(for: $0.day))
        }
        let daily = dailyGroups
            .map { key, rows in
                DailyTokenUsage(
                    date: key.day,
                    provider: key.provider,
                    inputTokens: rows.reduce(0) { $0 + max(0, $1.inputTokens) },
                    outputTokens: rows.reduce(0) { $0 + max(0, $1.outputTokens) },
                    cacheCreationTokens: rows.reduce(0) { $0 + max(0, $1.cacheCreationTokens) },
                    cacheReadTokens: rows.reduce(0) { $0 + max(0, $1.cacheReadTokens) },
                    estimatedCostUSD: rows.reduce(0) { $0 + max(0, $1.estimatedCostUSD) },
                    modelBreakdowns: [],
                    projectBreakdowns: [],
                    sessionBreakdowns: []
                )
            }
            .sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.provider.sortOrder < $1.provider.sortOrder
            }

        let providerGroups = Dictionary(grouping: daily, by: \.provider)
        let costs = providerGroups
            .map { provider, rows in
                TokenCost(
                    provider: provider,
                    inputTokens: rows.reduce(0) { $0 + $1.inputTokens },
                    outputTokens: rows.reduce(0) { $0 + $1.outputTokens },
                    cacheCreationTokens: rows.reduce(0) { $0 + $1.cacheCreationTokens },
                    cacheReadTokens: rows.reduce(0) { $0 + $1.cacheReadTokens },
                    estimatedCostUSD: rows.reduce(0) { $0 + $1.estimatedCostUSD },
                    sessionCount: 0,
                    periodStart: rows.map(\.date).min() ?? Date.distantPast,
                    periodEnd: rows.map(\.date).max() ?? Date.distantPast
                )
            }
            .sorted { $0.provider.sortOrder < $1.provider.sortOrder }

        let coveredDays: Int
        if let first = daily.map(\.date).min(), let last = daily.map(\.date).max() {
            coveredDays = max(1, (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1)
        } else {
            coveredDays = 0
        }

        return CostSummary(
            costs: costs,
            totalCostUSD: costs.reduce(0) { $0 + $1.estimatedCostUSD },
            totalTokens: costs.reduce(0) { $0 + $1.totalTokens },
            periodDays: coveredDays,
            dailyUsage: daily
        )
    }

    private static func stableTieBreak(_ rollup: ICloudDailyUsageRollup) -> String {
        let quota = rollup.quotaSnapshots
            .map { "\($0.provider.rawValue):\($0.accountIdentity):\($0.capturedAt.timeIntervalSinceReferenceDate)" }
            .sorted()
            .joined(separator: "|")
        return "\(rollup.inputTokens):\(rollup.outputTokens):\(rollup.cacheCreationTokens):"
            + "\(rollup.cacheReadTokens):"
            + "\(rollup.estimatedCostUSD):\(quota)"
    }
}
