import Foundation
import MeterBarShared

/// Maps the Kimi Code `GET /coding/v1/usages` body onto `UsageMetrics`.
///
/// The endpoint is first-party (the official Kimi Code client is open source)
/// but it is not an independently versioned REST contract, and it has already
/// changed shape once. The client's parser moved from a "rows" payload to a
/// "quota" payload on 2026-09-15, so this parser reads both:
///
///     quota:  { "usages": { "limit_5h": { "used_ratio": 0.3, "reset_time": "…" },
///                           "limit_7d": …, "limit_month_total": …, "limit_month_code": … },
///               "boosterWallet": { … } }
///     rows:   { "usage":  { "used": "40", "limit": "1000", "resetTime": "…" },
///               "limits": [ { "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
///                             "detail": { "used": "1", "limit": "100", "resetTime": "…" } } ],
///               "boosterWallet": { … } }
///
/// Both are tolerant of additive fields and of numbers arriving as strings.
/// The rule that matters is the negative one: a window, denominator or reset
/// that the payload does not carry is left out, never invented, and a payload
/// with no readable quota is a parse failure rather than a 0% reading.
nonisolated enum KimiCodeUsageParser {
    static let sessionWindowSeconds: TimeInterval = 5 * 3_600
    static let weeklyWindowSeconds: TimeInterval = 7 * 24 * 3_600
    private static let dayWindowSeconds: TimeInterval = 24 * 3_600

    /// One readable quota window before it is placed in a `UsageMetrics` slot.
    private struct Window {
        enum Kind {
            case fiveHour
            case sevenDay
            case monthTotal
            case monthCode
            /// A row-model window whose length is known (or, if not, `nil`).
            case other(seconds: TimeInterval?)
        }

        let kind: Kind
        let limit: UsageLimit
    }

    static func metrics(from data: Data, now: Date = Date()) throws -> UsageMetrics {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ServiceError.parsingError(nil)
        }

        var windows = quotaWindows(from: root["usages"])
        if windows.isEmpty {
            windows = rowWindows(from: root)
        }
        guard !windows.isEmpty else {
            throw ServiceError.parsingError(nil)
        }

        return place(windows, extraUsage: boosterWallet(from: root["boosterWallet"]), now: now)
    }

    // MARK: - Quota model

    private struct QuotaEntry {
        let key: String
        let kind: Window.Kind
        let seconds: TimeInterval?
        let period: UsageLimit.PeriodKind
        let label: String?
    }

    private static let quotaEntries: [QuotaEntry] = [
        QuotaEntry(key: "limit_5h", kind: .fiveHour, seconds: sessionWindowSeconds, period: .session, label: nil),
        QuotaEntry(key: "limit_7d", kind: .sevenDay, seconds: weeklyWindowSeconds, period: .weekly, label: nil),
        QuotaEntry(key: "limit_month_total", kind: .monthTotal, seconds: nil, period: .monthly, label: nil),
        QuotaEntry(key: "limit_month_code", kind: .monthCode, seconds: nil, period: .monthly, label: "Monthly code")
    ]

    private static func quotaWindows(from raw: Any?) -> [Window] {
        guard let usages = raw as? [String: Any] else { return [] }
        return quotaEntries.compactMap { entry in
            guard let object = usages[entry.key] as? [String: Any],
                  let ratio = number(object["used_ratio"]),
                  ratio >= 0 else {
                return nil
            }
            return Window(
                kind: entry.kind,
                limit: UsageLimit(
                    used: ratio * 100,
                    total: 100,
                    resetTime: date(object["reset_time"]),
                    windowSeconds: entry.seconds,
                    periodKind: entry.period,
                    label: entry.label
                )
            )
        }
    }

    // MARK: - Row model

    private static func rowWindows(from root: [String: Any]) -> [Window] {
        var windows: [Window] = []
        // The summary row is the plan's weekly limit; the backend omits its
        // window, so it is named here, as the official client does.
        if let summary = root["usage"] as? [String: Any],
           let limit = rowLimit(summary, seconds: weeklyWindowSeconds) {
            windows.append(Window(kind: .sevenDay, limit: limit))
        }
        if let limits = root["limits"] as? [Any] {
            for case let item as [String: Any] in limits {
                guard let detail = item["detail"] as? [String: Any] else { continue }
                let seconds = windowSeconds(item["window"] as? [String: Any])
                guard let limit = rowLimit(detail, seconds: seconds) else { continue }
                windows.append(Window(kind: kind(forRowSeconds: seconds), limit: limit))
            }
        }
        return windows
    }

    private static func rowLimit(_ row: [String: Any], seconds: TimeInterval?) -> UsageLimit? {
        guard let total = number(row["limit"]), total > 0 else { return nil }
        let used: Double
        if let reported = number(row["used"]) {
            used = reported
        } else if let remaining = number(row["remaining"]) {
            used = total - remaining
        } else {
            // Neither figure is present: report nothing rather than 0%.
            return nil
        }
        guard used >= 0 else { return nil }
        return UsageLimit(
            used: used,
            total: total,
            resetTime: date(row["resetTime"]),
            windowSeconds: seconds,
            periodKind: periodKind(forSeconds: seconds)
        )
    }

    /// `duration` + proto-style `timeUnit`. An unrecognised unit yields `nil`:
    /// the row is still shown, but as a neutral "Quota" window, never with a
    /// guessed cadence.
    private static func windowSeconds(_ window: [String: Any]?) -> TimeInterval? {
        guard let window,
              let duration = number(window["duration"]), duration > 0,
              let unit = window["timeUnit"] as? String else {
            return nil
        }
        switch unit {
        case "TIME_UNIT_MINUTE": return duration * 60
        case "TIME_UNIT_HOUR": return duration * 3_600
        case "TIME_UNIT_DAY": return duration * dayWindowSeconds
        case "TIME_UNIT_WEEK": return duration * weeklyWindowSeconds
        default: return nil
        }
    }

    private static func kind(forRowSeconds seconds: TimeInterval?) -> Window.Kind {
        switch seconds {
        case sessionWindowSeconds: return .fiveHour
        case weeklyWindowSeconds: return .sevenDay
        default: return .other(seconds: seconds)
        }
    }

    private static func periodKind(forSeconds seconds: TimeInterval?) -> UsageLimit.PeriodKind {
        guard let seconds else { return .unknown }
        switch seconds {
        case sessionWindowSeconds: return .session
        case dayWindowSeconds: return .daily
        case weeklyWindowSeconds: return .weekly
        default: return .unknown
        }
    }

    // MARK: - Slot placement

    /// Fills `sessionLimit` with the 5-hour window and `weeklyLimit` with the
    /// weekly one (or, when the plan reports no weekly window, the longest
    /// remaining cadence, so the provider still drives status and pace).
    /// Everything else rides in `additionalLimits`.
    private static func place(_ windows: [Window], extraUsage: ExtraUsageStatus?, now: Date) -> UsageMetrics {
        var remaining = windows
        func take(where matches: (Window.Kind) -> Bool) -> UsageLimit? {
            guard let index = remaining.firstIndex(where: { matches($0.kind) }) else { return nil }
            return remaining.remove(at: index).limit
        }

        let session = take { if case .fiveHour = $0 { return true } else { return false } }
        var weekly = take { if case .sevenDay = $0 { return true } else { return false } }
        if weekly == nil {
            weekly = take { if case .monthTotal = $0 { return true } else { return false } }
        }

        return UsageMetrics(
            service: .kimiCode,
            sessionLimit: session,
            weeklyLimit: weekly,
            extraUsage: extraUsage,
            additionalLimits: remaining.map(\.limit),
            lastUpdated: now
        )
    }

    // MARK: - Booster wallet

    /// The booster wallet (Kimi's pay-as-you-go top-up) maps to
    /// `ExtraUsageStatus` only when its amounts *and* currency are readable.
    /// Amounts arrive as fixed-point values where 1_000_000 == one cent.
    private static func boosterWallet(from raw: Any?) -> ExtraUsageStatus? {
        guard let wallet = raw as? [String: Any],
              let balance = wallet["balance"] as? [String: Any],
              balance["type"] as? String == "BOOSTER",
              let total = number(balance["amount"]), total > 0,
              let left = number(balance["amountLeft"]), left >= 0,
              let currency = walletCurrency(wallet) else {
            return nil
        }
        let fixedPointPerCent = 1_000_000.0
        let totalAmount = total / fixedPointPerCent / 100
        let leftAmount = min(left, total) / fixedPointPerCent / 100
        let format = { (amount: Double) in ExtraUsageStatus.formatAmount(amount, currency: currency) }
        return ExtraUsageStatus(
            state: leftAmount > 0 ? .on : .off,
            detail: "\(format(leftAmount)) left of \(format(totalAmount))"
        )
    }

    /// The wallet's balance carries no currency of its own; it is stated on the
    /// monthly charge limit or monthly spend. Anything that is not a plain
    /// three-letter code is treated as unreadable.
    private static func walletCurrency(_ wallet: [String: Any]) -> String? {
        for key in ["monthlyChargeLimit", "monthlyUsed"] {
            guard let money = wallet[key] as? [String: Any],
                  let code = money["currency"] as? String else { continue }
            let normalized = code.uppercased()
            if normalized.count == 3, normalized.allSatisfy({ $0 >= "A" && $0 <= "Z" }) {
                return normalized
            }
        }
        return nil
    }

    // MARK: - Scalars

    /// A finite number, given as a JSON number or a numeric string.
    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            // `NSNumber` also wraps booleans; a boolean is not a quantity.
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let result = number.doubleValue
            return result.isFinite ? result : nil
        case let string as String:
            guard let result = Double(string.trimmingCharacters(in: .whitespaces)), result.isFinite else {
                return nil
            }
            return result
        default:
            return nil
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: string) { return parsed }
        return ISO8601DateFormatter().date(from: string)
    }
}
