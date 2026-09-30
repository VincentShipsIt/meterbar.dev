import Foundation

/// Whose Copilot billing the token is asked about.
public enum GitHubCopilotBillingScope: String, Codable, CaseIterable, Sendable, Equatable {
    /// A personal plan billed directly to the user's own GitHub account
    /// (`/users/{username}/settings/billing/...`).
    case personal
    /// A licence managed and billed through an organization or enterprise, read
    /// through the organization's budget endpoint by someone with the billing
    /// role (`/organizations/{org}/settings/billing/budgets`).
    case organization

    public var displayName: String {
        switch self {
        case .personal: return "Personal plan"
        case .organization: return "Organization-managed"
        }
    }
}

/// GitHub logins are interpolated into a URL path, so they are validated to
/// GitHub's own rule (alphanumerics and single hyphens, at most 39 characters)
/// before they can reach a request. Anything else is rejected, never escaped
/// into something that might still resolve.
public enum GitHubLogin {
    public static func isValid(_ value: String) -> Bool {
        guard (1...39).contains(value.count),
              value.first != "-", value.last != "-",
              !value.contains("--") else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57)
                || ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122)
                || $0 == "-"
        }
    }
}

/// What MeterBar can honestly say about a Copilot account.
///
/// GitHub documents versioned billing-usage endpoints (`2026-03-10`) but no
/// single allowance for every plan: personal AI credits and legacy premium
/// requests report *usage* only, and the one documented cap is an organization
/// user-level budget read by a billing manager. So a quota bar exists only for
/// `.quota`; every other account is shown a precise state instead of a guessed
/// allowance.
public enum GitHubCopilotAccountSupport: Codable, Sendable, Equatable {
    /// A documented user-level budget (cap and consumed amount) is readable.
    case quota
    /// Usage is readable but GitHub documents no allowance to compare it to.
    case usageOnly(UsageOnlyReason)
    /// The account shape cannot be read at all.
    case unsupported(UnsupportedReason)

    public enum UsageOnlyReason: String, Codable, Sendable, Equatable {
        /// Personal AI-credit plan: usage is reported, an allowance is not.
        case noDocumentedAllowance
        /// Legacy premium-request plan: usage is reported, the entitlement is not.
        case legacyEntitlementUndocumented
        /// Organization scope, but no user-level budget applies to this user.
        case noUserBudget
        /// The personal endpoint answered with no usage: a licence managed by an
        /// organization is not included in user-level reports.
        case noPersonalUsage
    }

    public enum UnsupportedReason: String, Codable, Sendable, Equatable {
        /// 403: the token lacks the documented permission or the user lacks the billing role.
        case missingPermission
        /// 404: the account is not on the billing platform these endpoints need.
        case notAvailable
        /// The budget that applies is not a Copilot AI-credit or premium-request budget.
        case budgetNotForCopilot
    }

    /// Stable, secret-free token persisted for the CLI's `doctor` and used in
    /// diagnostics.
    public var token: String {
        switch self {
        case .quota: return "quota"
        case let .usageOnly(reason): return "usageOnly.\(reason.rawValue)"
        case let .unsupported(reason): return "unsupported.\(reason.rawValue)"
        }
    }

    public init?(token: String) {
        let parts = token.split(separator: ".", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count > 1 ? parts[1] : nil) {
        case ("quota"?, nil):
            self = .quota
        case ("usageOnly"?, let raw?):
            guard let reason = UsageOnlyReason(rawValue: raw) else { return nil }
            self = .usageOnly(reason)
        case ("unsupported"?, let raw?):
            guard let reason = UnsupportedReason(rawValue: raw) else { return nil }
            self = .unsupported(reason)
        default:
            return nil
        }
    }

    /// Plain-language explanation, safe to paste into a public issue.
    public var message: String {
        switch self {
        case .quota:
            return "A documented user-level Copilot budget is readable."
        case .usageOnly(.noDocumentedAllowance):
            return "Copilot AI-credit usage is readable, but GitHub documents no allowance for personal plans."
        case .usageOnly(.legacyEntitlementUndocumented):
            return "Legacy premium-request usage is readable, but the entitlement is not documented by the API."
        case .usageOnly(.noUserBudget):
            return "No user-level Copilot budget applies to this user, so there is no cap to compare against."
        case .usageOnly(.noPersonalUsage):
            return "The personal billing report is empty. A licence managed by an organization is reported "
                + "through that organization instead."
        case .unsupported(.missingPermission):
            return "GitHub refused the request: the token needs the Plan (user) read permission, or the user "
                + "needs the organization billing role."
        case .unsupported(.notAvailable):
            return "GitHub reports these billing endpoints are not available for this account."
        case .unsupported(.budgetNotForCopilot):
            return "The budget that applies to this user is not a Copilot AI-credit or premium-request budget."
        }
    }

    public var isQuota: Bool { self == .quota }
}
