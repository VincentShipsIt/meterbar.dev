import Foundation
import MeterBarShared

/// A Muse Code account payload reduced to the fields MeterBar is allowed to keep.
///
/// `subs_usage` is optional. Meta omits it while the 5-hour window is idle,
/// including when the weekly window has usage. That is `.idle`, not 0% and not
/// a parse failure. A present `subs_usage` that is not an object, or an object
/// with no readable window, is drift and throws.
enum MuseCodeUsageReading: Equatable {
    case quota(plan: String?, session: UsageLimit?, weekly: UsageLimit?)
    case idle(plan: String?)
    case inactive(plan: String?)
    case paymentRequired(plan: String?)
}

/// Maps `POST /muse-code/key` onto quota windows.
///
/// The endpoint is the one Meta's own CLI uses for `/usage`. It is not a
/// versioned public API. Only `is_subs_active`, `require_payment`,
/// `subs_tier_name`, and `subs_usage` are read. Every other field — including
/// the minted `api_key`, payment flags, and the account's name, email, and
/// avatar — is discarded and never copied into the result.
///
/// `resets_at` is Unix seconds. `used_percent` is stored raw, including values
/// above 100. `UsageLimit.percentage` clamps the bar, and `>= 100` is exhausted.
nonisolated enum MuseCodeUsageParser {
    static let weeklyWindowSeconds: TimeInterval = 7 * 24 * 3_600
    /// Larger than any real reset and still an exact integer in a `Double`
    /// (the year 4000). Equality is accepted; anything greater is dropped.
    static let maximumResetSeconds: Double = 64_092_211_200

    static func parse(_ data: Data) throws -> MuseCodeUsageReading {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ServiceError.parsingError(nil)
        }
        guard let isActive = jsonBool(root["is_subs_active"]) else {
            throw ServiceError.parsingError(nil)
        }
        let requiresPayment = try paymentFlag(root["require_payment"])
        let plan = planName(root["subs_tier_name"])
        if requiresPayment {
            return .paymentRequired(plan: plan)
        }
        if !isActive {
            return .inactive(plan: plan)
        }
        return try quota(from: root["subs_usage"], plan: plan)
    }

    /// Absent or JSON null means the account is not blocked on billing.
    /// A present value that is not a JSON boolean is drift.
    private static func paymentFlag(_ value: Any?) throws -> Bool {
        if value == nil || value is NSNull {
            return false
        }
        guard let flag = jsonBool(value) else {
            throw ServiceError.parsingError(nil)
        }
        return flag
    }

    private static func quota(from raw: Any?, plan: String?) throws -> MuseCodeUsageReading {
        if raw == nil || raw is NSNull {
            return .idle(plan: plan)
        }
        guard let usage = raw as? [String: Any] else {
            throw ServiceError.parsingError(nil)
        }
        let session = window(usage["window"], period: .session, fixedSeconds: nil)
        let weekly = window(usage["weekly"], period: .weekly, fixedSeconds: weeklyWindowSeconds)
        guard session != nil || weekly != nil else {
            throw ServiceError.parsingError(nil)
        }
        return .quota(plan: plan, session: session, weekly: weekly)
    }

    /// `fixedSeconds` is the weekly cadence, which the payload does not carry.
    /// The session window uses a positive integer `window_duration_mins`.
    /// A missing or invalid duration keeps the percentage and drops only the
    /// window length — five hours is never invented.
    private static func window(
        _ raw: Any?,
        period: UsageLimit.PeriodKind,
        fixedSeconds: TimeInterval?
    ) -> UsageLimit? {
        guard let object = raw as? [String: Any], let percent = integer(object["used_percent"]) else {
            return nil
        }
        let seconds: TimeInterval?
        if let fixedSeconds {
            seconds = fixedSeconds
        } else if let minutes = integer(object["window_duration_mins"]), minutes > 0 {
            seconds = TimeInterval(minutes) * 60
        } else {
            seconds = nil
        }
        return UsageLimit(
            used: min(Double(percent), 100),
            total: 100,
            resetTime: resetDate(object["resets_at"]),
            windowSeconds: seconds,
            periodKind: period
        )
    }

    private static func planName(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// JSON `true` / `false` only. A numeric 0 or 1 is a different type.
    private static func jsonBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    /// A non-negative integer, as a JSON number or an integer string.
    /// Fractional, negative, boolean, and non-finite values are unreadable.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = finiteNumber(value), number >= 0, number <= Double(Int.max) else {
            return nil
        }
        let integral = number.rounded(.towardZero)
        guard number == integral else { return nil }
        return Int(integral)
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let result = number.doubleValue
            return result.isFinite ? result : nil
        case let string as String:
            guard let result = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)),
                  result.isFinite else {
                return nil
            }
            return result
        default:
            return nil
        }
    }

    /// Unix seconds. `<= 0` and values past `maximumResetSeconds` drop the
    /// reset only; the caller still keeps the percentage.
    private static func resetDate(_ value: Any?) -> Date? {
        guard let number = finiteNumber(value), number > 0, number <= maximumResetSeconds else {
            return nil
        }
        return Date(timeIntervalSince1970: number)
    }
}
