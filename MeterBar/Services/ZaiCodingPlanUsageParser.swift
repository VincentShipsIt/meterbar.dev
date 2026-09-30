import Foundation
import MeterBarShared

/// Maps the Z.ai / Zhipu `GET /api/monitor/usage/quota/limit` body onto
/// `UsageMetrics`.
///
/// The endpoint is what Z.ai's official usage-query plugin calls
/// (`zai-org/zai-coding-plugins`, `query-usage.mjs`). It is first-party but not
/// presented as a versioned REST contract, so this parser only trusts what the
/// response itself states:
///
///     { "code": 200, "success": true,
///       "data": { "level": "pro", "limits": [
///         { "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 12, "nextResetTime": 1790000000000 },
///         { "type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 4,  "nextResetTime": … },
///         { "type": "TIME_LIMIT",   "unit": 5, "number": 1, "usage": 1000, "currentValue": 120, "remaining": 880,
///           "percentage": 12, "usageDetails": [ … ] } ] } }
///
/// - `TOKENS_LIMIT` is a credit window reported only as a used `percentage`.
///   `unit`/`number` name its length (3 = hours, 6 = weeks, 1 = days, 5 =
///   months — the mapping the ecosystem's clients agree on; Z.ai does not
///   document it, so any other unit is shown as a neutral "Quota" window).
/// - `TIME_LIMIT` is the monthly MCP tool allowance, with absolute counts.
/// - Anything else, and any entry without a readable figure, is dropped.
///
/// A user's remaining quota is never derived from the advertised Lite / Pro /
/// Max allowances, and a payload with no readable window is a parse failure,
/// not 0%.
nonisolated enum ZaiCodingPlanUsageParser {
    struct Result {
        let metrics: UsageMetrics
        /// The plan tier the response names (`lite`, `pro`, `max`), if it is a
        /// plain short token.
        let plan: String?
    }

    static let sessionWindowSeconds: TimeInterval = 5 * 3_600
    static let weeklyWindowSeconds: TimeInterval = 7 * 24 * 3_600
    private static let dayWindowSeconds: TimeInterval = 24 * 3_600

    private struct Window {
        enum Kind { case session, weekly, other }
        let kind: Kind
        let limit: UsageLimit
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> Result {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ServiceError.parsingError(nil)
        }
        try checkEnvelope(root)

        guard let payload = root["data"] as? [String: Any],
              let rawLimits = payload["limits"] as? [Any] else {
            throw ServiceError.parsingError(nil)
        }

        var windows: [Window] = []
        for case let item as [String: Any] in rawLimits {
            switch (item["type"] as? String)?.uppercased() {
            case "TOKENS_LIMIT", "TOKEN_LIMIT":
                if let window = tokenWindow(item) { windows.append(window) }
            case "TIME_LIMIT", "TIME_USAGE_LIMIT":
                if let window = toolWindow(item) { windows.append(window) }
            default:
                continue
            }
        }
        guard !windows.isEmpty else { throw ServiceError.parsingError(nil) }

        var remaining = windows
        func take(_ kind: Window.Kind) -> UsageLimit? {
            guard let index = remaining.firstIndex(where: { $0.kind == kind }) else { return nil }
            return remaining.remove(at: index).limit
        }
        let metrics = UsageMetrics(
            service: .zaiCodingPlan,
            sessionLimit: take(.session),
            weeklyLimit: take(.weekly),
            additionalLimits: remaining.map(\.limit),
            lastUpdated: now
        )
        return Result(metrics: metrics, plan: plan(from: payload["level"]))
    }

    // MARK: - Envelope

    /// The API answers HTTP 200 with a failure `code` for a bad key, so the
    /// envelope is checked before anything is read from `data`.
    private static func checkEnvelope(_ root: [String: Any]) throws {
        if root["success"] as? Bool == false || (number(root["code"]).map { $0 != 200 } ?? false) {
            let code = number(root["code"]).flatMap { Int(exactly: $0) } ?? 0
            if code == 401 || (1000...1004).contains(code) {
                throw ServiceError.notAuthenticated
            }
            throw ServiceError.apiError("Request failed")
        }
    }

    // MARK: - Windows

    private static func tokenWindow(_ item: [String: Any]) -> Window? {
        guard let percentage = number(item["percentage"]), percentage >= 0 else { return nil }
        let unit = number(item["unit"])
        let count = number(item["number"])
        let seconds: TimeInterval?
        let kind: Window.Kind
        if unit == nil, count == nil {
            // The official plugin's own reading of an un-annotated token limit:
            // "Token usage (5 Hour)".
            seconds = sessionWindowSeconds
            kind = .session
        } else {
            seconds = windowSeconds(unit: unit, count: count)
            switch seconds {
            case sessionWindowSeconds: kind = .session
            case weeklyWindowSeconds: kind = .weekly
            default: kind = .other
            }
        }
        return Window(
            kind: kind,
            limit: UsageLimit(
                used: percentage,
                total: 100,
                resetTime: date(item["nextResetTime"]),
                windowSeconds: seconds,
                periodKind: periodKind(forSeconds: seconds, unit: unit)
            )
        )
    }

    /// The monthly MCP tool allowance. Only shown when the response gives an
    /// absolute cap: a plan that reports no cap has nothing to be a percentage
    /// of, and 0-of-0 must not read as a healthy window.
    private static func toolWindow(_ item: [String: Any]) -> Window? {
        guard let cap = number(item["usage"]), cap > 0 else { return nil }
        let used: Double
        if let current = number(item["currentValue"]) {
            used = current
        } else if let left = number(item["remaining"]) {
            used = cap - left
        } else {
            return nil
        }
        guard used >= 0 else { return nil }
        return Window(
            kind: .other,
            limit: UsageLimit(
                used: used,
                total: cap,
                resetTime: date(item["nextResetTime"]),
                periodKind: .monthly,
                label: "MCP tools"
            )
        )
    }

    private static func windowSeconds(unit: Double?, count: Double?) -> TimeInterval? {
        guard let unit, let code = Int(exactly: unit), let count, count > 0 else {
            return nil
        }
        switch code {
        case 1: return count * dayWindowSeconds
        case 3: return count * 3_600
        case 6: return count * weeklyWindowSeconds
        default: return nil
        }
    }

    private static func periodKind(forSeconds seconds: TimeInterval?, unit: Double?) -> UsageLimit.PeriodKind {
        if let unit, Int(exactly: unit) == 5 {
            return .monthly
        }
        switch seconds {
        case sessionWindowSeconds: return .session
        case weeklyWindowSeconds: return .weekly
        case dayWindowSeconds: return .daily
        default: return .unknown
        }
    }

    // MARK: - Scalars

    private static func plan(from value: Any?) -> String? {
        guard let level = (value as? String)?.trimmingCharacters(in: .whitespaces),
              !level.isEmpty, level.count <= 24,
              level.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        return level
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue.isFinite ? number.doubleValue : nil
        case let string as String:
            guard let result = Double(string.trimmingCharacters(in: .whitespaces)), result.isFinite else {
                return nil
            }
            return result
        default:
            return nil
        }
    }

    /// `nextResetTime` is epoch milliseconds; a value small enough to be
    /// seconds is read as seconds, and an ISO-8601 string is accepted too.
    private static func date(_ value: Any?) -> Date? {
        if let epoch = number(value) {
            guard epoch > 0 else { return nil }
            return Date(timeIntervalSince1970: epoch > 100_000_000_000 ? epoch / 1_000 : epoch)
        }
        guard let string = value as? String, !string.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
