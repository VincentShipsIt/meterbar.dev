import Foundation
import MeterBarShared
import XCTest

final class GitHubCopilotSupportTests: XCTestCase {
    func testEveryClassificationRoundTripsThroughItsPersistedToken() {
        let all: [GitHubCopilotAccountSupport] = [
            .quota,
            .usageOnly(.noDocumentedAllowance),
            .usageOnly(.legacyEntitlementUndocumented),
            .usageOnly(.noUserBudget),
            .usageOnly(.noPersonalUsage),
            .unsupported(.missingPermission),
            .unsupported(.notAvailable),
            .unsupported(.budgetNotForCopilot)
        ]
        for support in all {
            XCTAssertEqual(GitHubCopilotAccountSupport(token: support.token), support, support.token)
            XCTAssertFalse(support.message.isEmpty)
        }
        XCTAssertEqual(Set(all.map(\.token)).count, all.count, "tokens are unique")
    }

    func testOnlyQuotaIsQuota() {
        XCTAssertTrue(GitHubCopilotAccountSupport.quota.isQuota)
        XCTAssertFalse(GitHubCopilotAccountSupport.usageOnly(.noUserBudget).isQuota)
        XCTAssertFalse(GitHubCopilotAccountSupport.unsupported(.notAvailable).isQuota)
    }

    func testUnknownTokensAreRejected() {
        for token in ["", "quota.extra", "usageOnly", "usageOnly.nope", "unsupported.", "bogus.x", "Quota"] {
            XCTAssertNil(GitHubCopilotAccountSupport(token: token), token)
        }
    }

    func testMessagesNeverPromiseAnAllowance() {
        let unsupported: [GitHubCopilotAccountSupport] = [
            .usageOnly(.noDocumentedAllowance), .usageOnly(.legacyEntitlementUndocumented), .usageOnly(.noUserBudget)
        ]
        for support in unsupported {
            XCTAssertFalse(support.message.contains("1,000"), support.message)
            XCTAssertFalse(support.message.lowercased().contains("includes"), support.message)
        }
    }

    func testGitHubLoginValidationFollowsGitHubsRule() {
        for valid in ["octocat", "a", "Octo-Cat", "user123", String(repeating: "a", count: 39), "a-b-c"] {
            XCTAssertTrue(GitHubLogin.isValid(valid), valid)
        }
        for invalid in [
            "", "-leading", "trailing-", "double--hyphen", String(repeating: "a", count: 40), "has space",
            "octo/cat", "octo..cat", "octo?x=1", "octo#", "üser", "octo_cat", "octo%2Fcat", "../etc"
        ] {
            XCTAssertFalse(GitHubLogin.isValid(invalid), invalid)
        }
    }
}
