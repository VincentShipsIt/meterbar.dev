import Foundation
import MeterBarShared

/// Decoders and account classification for GitHub's documented billing
/// endpoints (REST API version `2026-03-10`):
///
/// - `GET /users/{username}/settings/billing/ai_credit/usage`
/// - `GET /users/{username}/settings/billing/premium_request/usage`
/// - `GET /organizations/{org}/settings/billing/budgets?user={login}`
///
/// The usage reports carry usage only. The one documented cap is an organization
/// user-level budget (`effective_budget`), so that is the only shape that yields
/// a quota; the rest are classified as usage-only or unsupported and never given
/// a guessed allowance. Nothing here is read from Copilot's CLI, its TUI, or any
/// undocumented endpoint.
nonisolated enum GitHubCopilotBillingParser {
    // MARK: Internal

    /// One report's totals. Each field is summed **independently** across the
    /// report's line items: gross, discount, and net are three views of the same
    /// usage, so they are never added to one another.
    struct UsageTotals: Equatable {
        /// Units consumed before the included-allowance discount.
        var grossQuantity = 0.0
        var discountQuantity = 0.0
        /// Units billed after the discount.
        var netQuantity = 0.0
        var netAmount = 0.0
        /// How many line items carried a recognised unit and were summed.
        var itemCount = 0

        var hasUsage: Bool {
            itemCount > 0 && grossQuantity > 0
        }
    }

    struct Budget: Equatable {
        let id: String
        let skus: Set<String>
        let amount: Double?
        let consumed: Double?
    }

    struct EffectiveBudget: Equatable {
        let id: String?
        let amount: Double
        let consumed: Double
    }

    struct BudgetsPage: Equatable {
        let budgets: [Budget]
        let effective: EffectiveBudget?
        let hasNextPage: Bool
    }

    enum Unit {
        case credits
        case requests

        // MARK: Fileprivate

        fileprivate var accepted: Set<String> {
            switch self {
            case .credits: ["credits", "ai-credits", "ai_credits", "ai credits"]
            case .requests: ["requests", "request", "premium-requests"]
            }
        }
    }

    enum BudgetOutcome: Equatable {
        case quota(used: Double, total: Double)
        case support(GitHubCopilotAccountSupport)
    }

    static let copilotBudgetSKUs: Set = ["ai_credits", "premium_requests"]

    // MARK: - Usage reports

    /// `usageItems` must be present (an empty array is a legitimate "no usage
    /// yet"); a body without it is not a usage report at all. Items whose
    /// `unitType` is not the expected unit are skipped rather than summed into
    /// a total they do not belong to.
    static func usage(from data: Data, unit: Unit) throws -> UsageTotals {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["usageItems"] as? [Any] else {
            throw ServiceError.parsingError(nil)
        }
        var totals = UsageTotals()
        for case let item as [String: Any] in items {
            guard let unitType = (item["unitType"] as? String)?.lowercased(),
                  unit.accepted.contains(unitType),
                  let gross = number(item["grossQuantity"]), gross >= 0 else {
                continue
            }
            totals.grossQuantity += gross
            totals.discountQuantity += max(0, number(item["discountQuantity"]) ?? 0)
            totals.netQuantity += max(0, number(item["netQuantity"]) ?? 0)
            totals.netAmount += max(0, number(item["netAmount"]) ?? 0)
            totals.itemCount += 1
        }
        guard totals.grossQuantity.isFinite, totals.discountQuantity.isFinite,
              totals.netQuantity.isFinite, totals.netAmount.isFinite else {
            throw ServiceError.apiError("Request failed")
        }
        return totals
    }

    // MARK: - Budgets

    static func budgets(from data: Data) throws -> BudgetsPage {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawBudgets = root["budgets"] as? [Any] else {
            throw ServiceError.parsingError(nil)
        }
        let budgets = rawBudgets.compactMap { raw -> Budget? in
            guard let item = raw as? [String: Any], let id = item["id"] as? String else {
                return nil
            }
            var skus = Set<String>()
            if let sku = item["budget_product_sku"] as? String {
                skus.insert(sku.lowercased())
            }
            if let list = item["budget_product_skus"] as? [Any] {
                skus.formUnion(list.compactMap { ($0 as? String)?.lowercased() })
            }
            return Budget(
                id: id,
                skus: skus,
                amount: number(item["budget_amount"]),
                consumed: number(item["consumed_amount"])
            )
        }
        var effective: EffectiveBudget?
        if let raw = root["effective_budget"] as? [String: Any],
           let amount = number(raw["budget_amount"]),
           let consumed = number(raw["consumed_amount"]),
           amount > 0, consumed >= 0 {
            effective = EffectiveBudget(id: raw["id"] as? String, amount: amount, consumed: consumed)
        }
        return BudgetsPage(
            budgets: budgets,
            effective: effective,
            hasNextPage: root["has_next_page"] as? Bool ?? false
        )
    }

    /// The organization path. A quota needs an effective user-level budget
    /// **and** evidence it is a Copilot budget: user-level budgets can only be
    /// created for the `ai_credits` / `premium_requests` SKUs, so a budget that
    /// is listed under any other SKU — or not listed at all — is not trusted.
    static func classify(_ pages: [BudgetsPage]) -> BudgetOutcome {
        guard let effective = pages.compactMap(\.effective).first else {
            return .support(.usageOnly(.noUserBudget))
        }
        let listed = pages.flatMap(\.budgets).first { $0.id == effective.id }
        guard let listed, !listed.skus.isDisjoint(with: copilotBudgetSKUs) else {
            return .support(.unsupported(.budgetNotForCopilot))
        }
        return .quota(used: effective.consumed, total: effective.amount)
    }

    // MARK: Private

    // MARK: - Scalars

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return nil
            }
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
}
