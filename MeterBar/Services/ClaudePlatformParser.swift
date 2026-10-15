import Foundation
import MeterBarShared

/// Maps the Claude Console (`platform.claude.com`) billing responses onto
/// `UsageMetrics`.
///
/// These are the undocumented endpoints the Console billing page itself calls,
/// read with the signed-in `sessionKey` cookie — a plain `sk-ant-api…` key and
/// the Admin API cannot read an individual organization's balance. Shapes are
/// taken from CodexBar's Claude Platform provider (a secondary witness) and are
/// fixture-tested here; anything unreadable is a parse failure, never $0.
///
///     GET /api/organizations
///       [ { "uuid": "…", "name": "…", "capabilities": ["api", …] }, … ]
///     GET /api/organizations/{uuid}/prepaid/credits
///       { "amount": 18725, "currency": "USD",
///         "balance": { "credits": { "amount_minor": 18725, "exponent": 2 } },
///         "promo_tranches": [ { "remaining_amount_minor_units": 12475, "granted_amount_minor_units": 20000,
///                               "expires_at": "2026-10-28T00:00:00Z",
///                               "program_id": "subscription_api_credit", "name": "API credit (Max 20x)" } ],
///         "tranches": [ { … "program_id": "api_credits" } ] }
///     GET /api/organizations/{uuid}/current_spend
///       { "amount": 4321 }
///
/// Amounts are minor units divided by `10^exponent` (0–4, default 2). Credit
/// grants *expire*; they never reset, so no reset time is invented for them.
nonisolated enum ClaudePlatformParser {
    struct Organization: Equatable {
        let id: String
        let name: String?
    }

    struct Grant: Equatable {
        let label: String
        let program: String?
        let isPurchased: Bool
        let remaining: Double
        let granted: Double
        let expiresAt: Date?

        static let subscriptionProgram = "subscription_api_credit"

        var isSubscription: Bool { program == Self.subscriptionProgram }
    }

    struct Credits: Equatable {
        let balance: Double
        let currency: String
        let exponent: Int
        /// Unexpired grants with a positive grant size, soonest expiry first
        /// (unknown expiry last).
        let grants: [Grant]
    }

    struct Reading {
        let metrics: UsageMetrics
        /// In-memory only: balance, spend and expiry for the card note.
        let summary: Summary
    }

    struct Summary: Equatable {
        let organizationName: String?
        let balance: Double
        let currency: String
        let monthToDateSpend: Double?
        let nextExpiry: Date?
    }

    /// Cap on additional grant rows so a pathological payload cannot flood
    /// the card.
    static let maximumAdditionalGrants = 4
    private static let maximumGrantRecords = 200

    // MARK: - Organizations

    /// The organizations that own Console API billing, in listed order.
    /// Claude.ai chat organizations share the list and are ignored.
    static func apiOrganizations(_ data: Data) throws -> [Organization] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            throw ServiceError.parsingError(nil)
        }
        var result: [Organization] = []
        for case let item as [String: Any] in list {
            guard let capabilities = item["capabilities"] as? [Any],
                  capabilities.contains(where: { ($0 as? String) == "api" }) else {
                continue
            }
            guard let id = text(item["uuid"]), isSafePathComponent(id) else {
                throw ServiceError.parsingError(nil)
            }
            result.append(Organization(id: id, name: text(item["name"])))
        }
        return result
    }

    // MARK: - Credits

    static func credits(_ data: Data, now: Date = Date()) throws -> Credits {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ServiceError.parsingError(nil)
        }
        let currency = text(root["currency"]) ?? "USD"
        guard currency.count == 3, currency.allSatisfy({ $0.isASCII && $0.isUppercase }) else {
            throw ServiceError.parsingError(nil)
        }
        let exponent = try creditExponent(root["balance"])
        let scale = pow(10, Double(exponent))
        guard let balanceMinor = minorUnits(root["amount"]) else {
            throw ServiceError.parsingError(nil)
        }

        var grants: [Grant] = []
        var records = 0
        for (field, purchased) in [("promo_tranches", false), ("tranches", true)] {
            guard let raw = root[field], !(raw is NSNull) else { continue }
            guard let list = raw as? [Any] else { throw ServiceError.parsingError(nil) }
            records += list.count
            guard records <= maximumGrantRecords else { throw ServiceError.parsingError(nil) }
            for item in list {
                guard let tranche = item as? [String: Any],
                      let grantedMinor = minorUnits(tranche["granted_amount_minor_units"]),
                      let remainingMinor = minorUnits(tranche["remaining_amount_minor_units"]) else {
                    throw ServiceError.parsingError(nil)
                }
                // A malformed date is an unknown expiry, never a failed refresh.
                let expiresAt = date(tranche["expires_at"])
                if grantedMinor <= 0 { continue }
                if let expiresAt, expiresAt <= now { continue }
                grants.append(Grant(
                    label: text(tranche["name"]) ?? (purchased ? "Purchased credit" : "API credit"),
                    program: text(tranche["program_id"]),
                    isPurchased: purchased,
                    remaining: max(0, remainingMinor) / scale,
                    granted: grantedMinor / scale,
                    expiresAt: expiresAt
                ))
            }
        }
        grants.sort { lhs, rhs in
            switch (lhs.expiresAt, rhs.expiresAt) {
            case let (left?, right?): return left < right
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return false
            }
        }
        return Credits(balance: balanceMinor / scale, currency: currency, exponent: exponent, grants: grants)
    }

    /// Month-to-date spend. Optional: nil for anything unreadable, so a broken
    /// report never discards an authenticated balance.
    static func monthToDateSpend(_ data: Data, exponent: Int) -> Double? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let minor = minorUnits(root["amount"]), minor >= 0 else {
            return nil
        }
        return minor / pow(10, Double(exponent))
    }

    // MARK: - Metrics

    static func reading(
        credits: Credits,
        monthToDateSpend: Double?,
        organizationName: String?,
        now: Date = Date()
    ) throws -> Reading {
        // Limits are drawn in dollars; another currency would be mislabeled.
        guard credits.currency == "USD" else {
            throw ServiceError.apiError("Unsupported currency")
        }
        let grants = credits.grants
        // The soonest-expiring subscription grant with credit left is the one
        // about to be lost. An exhausted one is not a lane.
        let subscription = grants.first { $0.isSubscription && $0.remaining > 0 }
        let purchasedGrants = grants.filter(\.isPurchased)
        let purchased = purchasedGrants.first { $0.remaining > 0 } ?? purchasedGrants.first
        let primary = subscription ?? purchased

        var additional: [UsageLimit] = []
        if let purchased, purchased != primary {
            additional.append(limit(purchased))
        }
        for grant in grants where grant != primary && grant != purchased && grant.remaining > 0 {
            guard additional.count < maximumAdditionalGrants else { break }
            additional.append(limit(grant))
        }

        let weekly: UsageLimit?
        if let primary {
            weekly = limit(primary, title: false)
        } else if credits.balance > 0 {
            // Balance without a readable grant: a remainder, never a percent.
            weekly = UsageLimit(used: 0, total: credits.balance, resetTime: nil, reading: .remainder)
        } else {
            weekly = nil
        }

        let metrics = UsageMetrics(
            service: .claudePlatform,
            weeklyLimit: weekly,
            additionalLimits: additional,
            lastUpdated: now
        )
        let summary = Summary(
            organizationName: organizationName,
            balance: credits.balance,
            currency: credits.currency,
            monthToDateSpend: monthToDateSpend,
            nextExpiry: grants.first { $0.remaining > 0 }?.expiresAt
        )
        return Reading(metrics: metrics, summary: summary)
    }

    private static func limit(_ grant: Grant, title: Bool = true) -> UsageLimit {
        UsageLimit(
            used: max(0, grant.granted - min(grant.remaining, grant.granted)),
            total: grant.granted,
            resetTime: nil,
            label: title ? grant.label : nil
        )
    }

    // MARK: - Scalars

    /// `balance.credits.exponent`: 0–4, default 2 when absent.
    private static func creditExponent(_ balance: Any?) throws -> Int {
        guard let balance, !(balance is NSNull) else { return 2 }
        guard let balance = balance as? [String: Any] else { throw ServiceError.parsingError(nil) }
        guard let credits = balance["credits"], !(credits is NSNull) else { return 2 }
        guard let credits = credits as? [String: Any] else { throw ServiceError.parsingError(nil) }
        guard let reported = credits["exponent"], !(reported is NSNull) else { return 2 }
        guard let value = minorUnits(reported), value >= 0, value <= 4 else {
            throw ServiceError.parsingError(nil)
        }
        return Int(value)
    }

    /// A whole number in minor units; booleans, fractions and non-finite
    /// values are unreadable.
    private static func minorUnits(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let result = number.doubleValue
        guard result.isFinite, result == result.rounded(), abs(result) < 9_007_199_254_740_992 else {
            return nil
        }
        return result
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else {
            return nil
        }
        return string
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        (1...64).contains(value.count)
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = text(value) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

/// Reads the one credential the Console needs out of whatever the user pasted.
///
/// Accepts a whole `Cookie:` request header, a bare `sessionKey=…` pair, or the
/// raw value. Only the `sessionKey` value is kept (the rest of a copied header
/// is other cookies MeterBar has no use for), and a value that could break out
/// of a header is rejected.
nonisolated enum ClaudePlatformSessionKey {
    static let cookieName = "sessionKey"
    private static let maximumLength = 4_096

    static func normalized(_ pasted: String) -> String? {
        var text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("cookie:") {
            text = String(text.dropFirst("cookie:".count))
        }
        var candidate: String?
        for pair in text.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            if parts.count == 2, name == cookieName {
                candidate = String(parts[1]).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        if candidate == nil, !text.contains("="), !text.contains(";") {
            candidate = text.trimmingCharacters(in: .whitespaces)
        }
        guard let value = candidate, !value.isEmpty, value.count <= maximumLength,
              value.allSatisfy({ $0.isASCII && $0 != " " && $0 != ";" && $0 != "," && !$0.isNewline
                  && ($0.asciiValue ?? 0) > 0x20 && ($0.asciiValue ?? 0) < 0x7F }) else {
            return nil
        }
        return value
    }
}
