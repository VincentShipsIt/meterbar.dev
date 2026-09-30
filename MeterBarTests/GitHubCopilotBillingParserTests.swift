import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Redacted fixtures for GitHub's documented billing responses (API version
/// `2026-03-10`). Field names and shapes follow GitHub's OpenAPI description;
/// figures and logins are synthetic.
final class GitHubCopilotBillingParserTests: XCTestCase {

    // MARK: Internal

    // MARK: - Usage aggregation

    func testAggregationOverflowFailsWithoutPublishingNonfiniteTotals() {
        for field in ["grossQuantity", "discountQuantity", "netQuantity", "netAmount"] {
            let row = field == "grossQuantity"
                ? #"{"unitType":"credits","grossQuantity":1e308}"#
                : #"{"unitType":"credits","grossQuantity":1,"\#(field)":1e308}"#
            XCTAssertThrowsError(try usage(#"{"usageItems":[\#(row),\#(row)]}"#)) { error in
                guard case let ServiceError.apiError(message) = error else {
                    return XCTFail("expected sanitized API failure, got \(error)")
                }
                XCTAssertEqual(message, "Request failed")
            }
        }
    }

    func testLargeFiniteAndFractionalQuantitiesRemainReadable() throws {
        for quantity in ["1e100", "1.5"] {
            let totals = try usage(#"{"usageItems":[{"unitType":"credits","grossQuantity":\#(quantity)}]}"#)
            XCTAssertEqual(totals.grossQuantity, Double(quantity))
            XCTAssertTrue(totals.grossQuantity.isFinite)
        }
    }

    func testPersonalAICreditReportSumsEachFieldIndependently() throws {
        let totals = try usage("""
        {"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[
          {"product":"Copilot AI Credits","sku":"AI Credit","model":"GPT-5","unitType":"ai-credits",
           "pricePerUnit":0.01,"grossQuantity":100,"grossAmount":1,"discountQuantity":60,"discountAmount":0.6,
           "netQuantity":40,"netAmount":0.4},
          {"product":"Copilot AI Credits","sku":"AI Credit","model":"Claude","unitType":"ai-credits",
           "pricePerUnit":0.01,"grossQuantity":50,"grossAmount":0.5,"discountQuantity":0,"discountAmount":0,
           "netQuantity":50,"netAmount":0.5}]}
        """)

        XCTAssertEqual(totals.grossQuantity, 150)
        XCTAssertEqual(totals.discountQuantity, 60)
        XCTAssertEqual(totals.netQuantity, 90)
        XCTAssertEqual(totals.netAmount, 0.9, accuracy: 0.000_001)
        XCTAssertEqual(totals.itemCount, 2)
        XCTAssertTrue(totals.hasUsage)
    }

    func testGrossDiscountAndNetAreNeverAddedTogether() throws {
        let totals = try usage("""
        {"usageItems":[{"unitType":"credits","grossQuantity":100,"discountQuantity":100,"netQuantity":0,
                        "grossAmount":1,"discountAmount":1,"netAmount":0}]}
        """)

        // 100 consumed, all covered by the included allowance: nothing billed.
        XCTAssertEqual(totals.grossQuantity, 100)
        XCTAssertEqual(totals.netQuantity, 0)
        XCTAssertEqual(totals.netAmount, 0)
        XCTAssertNotEqual(totals.grossQuantity + totals.discountQuantity + totals.netQuantity, totals.grossQuantity)
    }

    func testLegacyPremiumRequestReportIsReadAsRequests() throws {
        let totals = try usage("""
        {"timePeriod":{"year":2026},"user":"octocat","usageItems":[
          {"product":"Copilot","sku":"Copilot Premium Request","model":"GPT-5","unitType":"requests",
           "pricePerUnit":0.04,"grossQuantity":100,"grossAmount":4,"discountQuantity":0,"discountAmount":0,
           "netQuantity":100,"netAmount":4}]}
        """, unit: .requests)

        XCTAssertEqual(totals.grossQuantity, 100)
        XCTAssertEqual(totals.netAmount, 4)
    }

    func testRowsInAnotherUnitAreSkippedNotSummedIntoTheTotal() throws {
        let totals = try usage("""
        {"usageItems":[
          {"unitType":"minutes","grossQuantity":9999,"netQuantity":9999,"netAmount":80},
          {"unitType":"ai-credits","grossQuantity":10,"netQuantity":10,"netAmount":0.1}]}
        """)

        XCTAssertEqual(totals.grossQuantity, 10)
        XCTAssertEqual(totals.itemCount, 1)
    }

    func testEmptyReportIsAnAnswerNotAnError() throws {
        let totals = try usage(#"{"timePeriod":{"year":2026},"user":"octocat","usageItems":[]}"#)

        XCTAssertFalse(totals.hasUsage)
        XCTAssertEqual(totals.itemCount, 0)
    }

    func testNumericStringsAndNegativeDiscountsAreHandled() throws {
        let totals =
            try usage(
                #"{"usageItems":[{"unitType":"credits","grossQuantity":"12","netQuantity":"12","discountQuantity":-5}]}"#
            )

        XCTAssertEqual(totals.grossQuantity, 12)
        XCTAssertEqual(totals.discountQuantity, 0, "a negative discount is clamped, never subtracted")
    }

    func testMalformedUsageBodiesAreParsingErrors() {
        for body in ["", "not json", "[]", "null", "{}", #"{"usageItems":"none"}"#, #"{"usageItems":{}}"#] {
            XCTAssertThrowsError(try usage(body), body) { error in
                guard case ServiceError.parsingError = error else {
                    return XCTFail("expected a parsing error for \(body), got \(error)")
                }
            }
        }
    }

    // MARK: - Budgets

    func testBudgetsPageParsesEffectiveBudgetAndPaginationFlag() throws {
        let page = try budgets("""
        {"budgets":[
          {"id":"b1","budget_type":"BundlePricing","budget_product_sku":"ai_credits","budget_scope":"user",
           "budget_amount":25,"prevent_further_usage":true,"user":"octocat","consumed_amount":9.5},
          {"id":"b2","budget_type":"ProductPricing","budget_product_skus":["actions"],"budget_scope":"organization",
           "budget_amount":1000,"prevent_further_usage":false}],
         "user":"octocat","effective_budget":{"id":"b1","budget_amount":25,"consumed_amount":9.5},
         "has_next_page":true,"total_count":2}
        """)

        XCTAssertEqual(page.budgets.count, 2)
        XCTAssertEqual(page.budgets[0].skus, ["ai_credits"])
        XCTAssertEqual(page.budgets[1].skus, ["actions"], "the array form of the SKU field is read too")
        XCTAssertEqual(page.effective, .init(id: "b1", amount: 25, consumed: 9.5))
        XCTAssertTrue(page.hasNextPage)
    }

    func testEffectiveBudgetWithoutACapOrConsumptionIsAbsent() throws {
        for effective in [
            #"{"id":"b1","budget_amount":0,"consumed_amount":0}"#,
            #"{"id":"b1","budget_amount":25}"#,
            #"{"id":"b1","consumed_amount":3}"#,
            #"{"id":"b1","budget_amount":25,"consumed_amount":-1}"#,
            #""none""#,
        ] {
            let page = try budgets(#"{"budgets":[],"effective_budget":\#(effective),"has_next_page":false}"#)
            XCTAssertNil(page.effective, effective)
        }
    }

    func testMalformedBudgetBodiesAreParsingErrors() {
        for body in ["", "[]", "{}", #"{"budgets":"none"}"#] {
            XCTAssertThrowsError(try budgets(body), body)
        }
    }

    func testAnEffectiveCopilotBudgetIsTheOnlyQuota() {
        XCTAssertEqual(
            GitHubCopilotBillingParser.classify([page(effectiveID: "b1", budgetID: "b1", sku: "ai_credits")]),
            .quota(used: 9, total: 25)
        )
        XCTAssertEqual(
            GitHubCopilotBillingParser.classify([page(effectiveID: "b1", budgetID: "b1", sku: "premium_requests")]),
            .quota(used: 9, total: 25)
        )
    }

    func testNoEffectiveBudgetMeansNoDocumentedCap() {
        XCTAssertEqual(
            GitHubCopilotBillingParser.classify([page(effectiveID: nil, budgetID: "b1", sku: "ai_credits")]),
            .support(.usageOnly(.noUserBudget))
        )
        XCTAssertEqual(GitHubCopilotBillingParser.classify([]), .support(.usageOnly(.noUserBudget)))
    }

    func testABudgetOnAnotherProductOrWithNoEvidenceIsNotTrusted() {
        XCTAssertEqual(
            GitHubCopilotBillingParser.classify([page(effectiveID: "b1", budgetID: "b1", sku: "actions")]),
            .support(.unsupported(.budgetNotForCopilot))
        )
        XCTAssertEqual(
            GitHubCopilotBillingParser.classify([page(effectiveID: "other", budgetID: "b1", sku: "ai_credits")]),
            .support(.unsupported(.budgetNotForCopilot)),
            "an effective budget that is not in the listing has no evidence it is Copilot's"
        )
    }

    func testTheEffectiveBudgetCanBeOnALaterPageThanItsListing() {
        let first = page(effectiveID: nil, budgetID: "b1", sku: "ai_credits", hasNext: true)
        let second = GitHubCopilotBillingParser.BudgetsPage(
            budgets: [],
            effective: .init(id: "b1", amount: 40, consumed: 4),
            hasNextPage: false
        )

        XCTAssertEqual(GitHubCopilotBillingParser.classify([first, second]), .quota(used: 4, total: 40))
    }

    // MARK: Private

    private func usage(_ json: String, unit: GitHubCopilotBillingParser.Unit = .credits) throws
        -> GitHubCopilotBillingParser.UsageTotals {
        try GitHubCopilotBillingParser.usage(from: Data(json.utf8), unit: unit)
    }

    private func budgets(_ json: String) throws -> GitHubCopilotBillingParser.BudgetsPage {
        try GitHubCopilotBillingParser.budgets(from: Data(json.utf8))
    }

    // MARK: - Classification

    private func page(effectiveID: String?, budgetID: String, sku: String, hasNext: Bool = false)
        -> GitHubCopilotBillingParser.BudgetsPage {
        .init(
            budgets: [.init(id: budgetID, skus: [sku], amount: 25, consumed: 9)],
            effective: effectiveID.map { .init(id: $0, amount: 25, consumed: 9) },
            hasNextPage: hasNext
        )
    }

}
