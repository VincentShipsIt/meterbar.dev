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
        XCTAssertEqual(PlanLabel.make(service: .xai, token: "pro_plus"), "Pro Plus")
        XCTAssertEqual(PlanLabel.make(service: .xai, token: "SuperGrok"), "SuperGrok")
        XCTAssertEqual(PlanLabel.make(service: .museCode, token: "Muse Code Everyday Usage"), "Everyday")
        XCTAssertEqual(PlanLabel.make(service: .museCode, token: "Muse Code High Usage"), "High")
        XCTAssertEqual(PlanLabel.make(service: .museCode, token: "Muse Code Power Usage"), "Power")
        XCTAssertEqual(PlanLabel.make(service: .museCode, token: "Muse Code Maximum Usage"), "Maximum")
    }

    func testEmptyTokenYieldsNoLabel() {
        XCTAssertNil(PlanLabel.make(service: .xai, token: nil))
        XCTAssertNil(PlanLabel.make(service: .xai, token: "  "))
    }

    func testPlanLandsOnlyOnTheCardThatOwnsTheCredentials() {
        let custom = CodexAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/work")
        var input = ProviderSnapshotBuilder.Input(
            metrics: [:],
            claudeAccounts: [],
            claudeAccountMetrics: [:],
            enabledServices: [.codexCli, .xai]
        )
        input.codexAccounts = [.defaultAccount, custom]
        input.planLabels = [.codexCli: "Pro", .xai: "Ultra"]
        let cards = ProviderSnapshotBuilder.snapshots(input)
        XCTAssertEqual(cards.first { $0.service == .xai }?.planLabel, "Ultra")
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

    func testOpenRouterTierReflectsWhetherCreditsWereEverBought() {
        XCTAssertEqual(PlanLabel.openRouterTier(isFreeTier: true), "Free")
        XCTAssertEqual(PlanLabel.openRouterTier(isFreeTier: false), "Pay as you go")
        XCTAssertNil(PlanLabel.openRouterTier(isFreeTier: nil))
    }

    func testEachOpenRouterKeyCarriesItsOwnTier() {
        let free = OpenRouterAccount(id: UUID(), name: "Side project")
        let paid = OpenRouterAccount(id: UUID(), name: "Work")
        var input = ProviderSnapshotBuilder.Input(
            metrics: [:],
            claudeAccounts: [],
            claudeAccountMetrics: [:],
            enabledServices: [.openRouter]
        )
        input.openRouterAccounts = [free, paid]
        input.accountPlanLabels = [free.id: "Free", paid.id: "Pay as you go"]
        let cards = ProviderSnapshotBuilder.snapshots(input)
        XCTAssertEqual(cards.first { $0.accountID == free.id }?.planLabel, "Free")
        XCTAssertEqual(cards.first { $0.accountID == paid.id }?.planLabel, "Pay as you go")
    }

    func testMuseCodePlanIsLabelled() {
        var input = ProviderSnapshotBuilder.Input(
            metrics: [:],
            claudeAccounts: [],
            claudeAccountMetrics: [:],
            enabledServices: [.museCode]
        )
        input.planLabels = [.museCode: PlanLabel.make(service: .museCode, token: "pro") ?? ""]
        XCTAssertEqual(ProviderSnapshotBuilder.snapshots(input).first?.planLabel, "Pro")
    }
}
