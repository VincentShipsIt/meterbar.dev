import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// The Routing page's presentation model: one row per task, answered by the
/// same pure router `meterbar route` uses, with nothing the router would not
/// print (no path, token, or prompt).
final class RoutingPreviewModelTests: XCTestCase {
    private let now = RoutingFixtures.now

    private func preview(
        catalog: RoutingPolicyCatalog = RoutingPolicyCatalog(),
        notice: RoutingReason? = nil,
        candidates: [RoutingCandidate]
    ) -> RoutingPreview {
        RoutingPreview.make(catalog: catalog, notice: notice, candidates: candidates, now: now)
    }

    func testOneRowPerCatalogTaskInDocumentedOrder() {
        let catalog = RoutingPolicyCatalog()
        let result = preview(candidates: [RoutingFixtures.candidate(.claudeCode)])

        XCTAssertEqual(result.rows.map(\.taskID), catalog.taskIDs.map(\.rawValue))
        XCTAssertEqual(Set(result.rows.map(\.id)).count, result.rows.count)
    }

    func testRecommendedRowCarriesHeadlineFallbacksAndReasons() throws {
        let result = preview(candidates: [
            RoutingFixtures.candidate(.claudeCode, used: 20),
            RoutingFixtures.candidate(.codexCli, used: 60),
        ])

        let row = try XCTUnwrap(result.rows.first { $0.outcome == .recommended })
        XCTAssertFalse(row.headline.isEmpty)
        XCTAssertFalse(row.reasons.isEmpty)
        XCTAssertFalse(row.isBlocked)
        // Whatever the policy prefers, the headline is the router's own label.
        let policy = try XCTUnwrap(RoutingPolicyCatalog().policy(for: RoutingTaskID(token: row.taskID)!))
        let decision = WorkloadRouter.route(policy: policy, candidates: [
            RoutingFixtures.candidate(.claudeCode, used: 20),
            RoutingFixtures.candidate(.codexCli, used: 60),
        ], now: now)
        let route = try XCTUnwrap(decision.recommendation)
        XCTAssertEqual(row.headline, WorkloadRouter.routeLabel(route, policy: policy))
        XCTAssertEqual(row.fallbacks, decision.fallbacks.map { WorkloadRouter.routeLabel($0, policy: policy) })
    }

    func testNoCandidatesIsDataUnavailableNotARoute() throws {
        let result = preview(candidates: [])

        let row = try XCTUnwrap(result.rows.first)
        XCTAssertNotEqual(row.outcome, .recommended)
        XCTAssertTrue(row.isBlocked)
        XCTAssertEqual(row.headline, "No route available")
        XCTAssertTrue(row.fallbacks.isEmpty)
        XCTAssertFalse(row.summary.isEmpty)
    }

    func testSkippedCandidatesExplainWhyAndFlagDataProblems() throws {
        let result = preview(candidates: [
            RoutingFixtures.candidate(.claudeCode, used: 20),
            RoutingFixtures.candidate(.codexCli, used: 20, age: 3 * 24 * 3600),
        ])

        let skippedRows = result.rows.filter { !$0.skipped.isEmpty }
        let skipped = try XCTUnwrap(skippedRows.first?.skipped.first { $0.code == .snapshotStale })
        XCTAssertTrue(skipped.isDataProblem)
        XCTAssertFalse(skipped.message.isEmpty)
    }

    func testCustomisedTasksAreFlagged() throws {
        var policy = RoutingFixtures.policy(.review)
        policy.minimumRemainingPercent = 50
        let catalog = RoutingPolicyCatalog(document: RoutingPolicyDocument(policies: [policy]))

        let result = preview(catalog: catalog, candidates: [RoutingFixtures.candidate(.claudeCode)])

        XCTAssertEqual(result.rows.filter(\.isCustomized).map(\.taskID), [RoutingTaskID.review.rawValue])
    }

    func testPolicyNoticeIsSurfacedVerbatim() {
        let notice = RoutingReason(code: .policyUnreadable, message: "Routing policies could not be read.")

        let result = preview(notice: notice, candidates: [])

        XCTAssertEqual(result.notice, "Routing policies could not be read.")
    }

    func testNoNoticeWhenPoliciesLoadedCleanly() {
        XCTAssertNil(preview(candidates: []).notice)
    }

    func testPreviewNeverLeaksPathsOrTokens() throws {
        let result = preview(candidates: [
            RoutingFixtures.candidate(.claudeCode, used: 20),
            RoutingFixtures.account(.codexCli, id: RoutingFixtures.uuid(1), name: "Work", used: 90),
        ])

        let text = result.rows.flatMap { row in
            [row.headline, row.summary] + row.reasons + row.fallbacks + row.skipped.map(\.message)
        }.joined(separator: "\n")
        XCTAssertFalse(text.contains("/Users/"))
        XCTAssertFalse(text.lowercased().contains("token"))
    }
}
