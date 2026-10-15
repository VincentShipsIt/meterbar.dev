import MeterBarShared
import XCTest
@testable import MeterBar

final class PlanLabelTests: XCTestCase {
    func testClaudeMaxCarriesTheTierMultiplier() {
        XCTAssertEqual(
            PlanLabel.make(service: .claudeCode, token: "max", rateLimitTier: "default_claude_max_20x"),
            "Max 20x"
        )
        XCTAssertEqual(
            PlanLabel.make(service: .claudeCode, token: "pro", rateLimitTier: "default_claude_ai"),
            "Pro"
        )
    }

    func testProviderTokensAreNormalised() {
        XCTAssertEqual(PlanLabel.make(service: .codexCli, token: "prolite"), "Pro Lite")
        XCTAssertEqual(PlanLabel.make(service: .codexCli, token: "plus"), "Plus")
        XCTAssertEqual(PlanLabel.make(service: .cursor, token: "pro_plus"), "Pro Plus")
        XCTAssertEqual(PlanLabel.make(service: .grok, token: "SuperGrok"), "SuperGrok")
    }

    func testEmptyTokenYieldsNoLabel() {
        XCTAssertNil(PlanLabel.make(service: .cursor, token: nil))
        XCTAssertNil(PlanLabel.make(service: .cursor, token: "  "))
    }

    func testPlanLandsOnlyOnTheCardThatOwnsTheCredentials() {
        let custom = CodexAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/work")
        var input = ProviderSnapshotBuilder.Input(
            metrics: [:],
            claudeAccounts: [],
            claudeAccountMetrics: [:],
            enabledServices: [.codexCli, .cursor]
        )
        input.codexAccounts = [.defaultAccount, custom]
        input.planLabels = [.codexCli: "Pro", .cursor: "Ultra"]
        let cards = ProviderSnapshotBuilder.snapshots(input)
        XCTAssertEqual(cards.first { $0.service == .cursor }?.planLabel, "Ultra")
        XCTAssertEqual(cards.first { $0.accountID == CodexAccount.defaultID }?.planLabel, "Pro")
        XCTAssertNil(cards.first { $0.accountID == custom.id }?.planLabel)
    }

    func testLoneCustomProfileDoesNotInheritTheDefaultAccountsPlan() {
        let custom = CodexAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/work")
        var input = ProviderSnapshotBuilder.Input(
            metrics: [:],
            claudeAccounts: [],
            claudeAccountMetrics: [:],
            enabledServices: [.codexCli]
        )
        var disabledDefault = CodexAccount.defaultAccount
        disabledDefault.isEnabled = false
        input.codexAccounts = [disabledDefault, custom]
        input.planLabels = [.codexCli: "Pro"]
        let cards = ProviderSnapshotBuilder.snapshots(input)
        XCTAssertEqual(cards.count, 1)
        XCTAssertNil(cards.first?.planLabel)
    }
}
