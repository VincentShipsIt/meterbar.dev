@testable import MeterBar
import XCTest

/// xAI is one subscription with two data sources (Grok CLI billing and Cursor),
/// so Settings shows one connection status and one plan label rather than a
/// section per source.
final class XAISettingsSummaryTests: XCTestCase {
    private func summary(
        grok: Bool = false,
        cursor: Bool = false,
        grokPlan: String? = nil,
        cursorPlan: String? = nil
    ) -> XAISettingsSummary {
        XAISettingsSummary(
            grokConnected: grok,
            cursorConnected: cursor,
            grokPlan: grokPlan,
            cursorPlan: cursorPlan
        )
    }

    func testConnectedWhenEitherSourceIsConnected() {
        XCTAssertTrue(summary(grok: true).isConnected)
        XCTAssertTrue(summary(cursor: true).isConnected)
        XCTAssertTrue(summary(grok: true, cursor: true).isConnected)
        XCTAssertFalse(summary().isConnected)
    }

    func testStatusTitleFollowsOverallConnection() {
        XCTAssertEqual(summary(cursor: true).statusTitle, "Connected")
        XCTAssertEqual(summary().statusTitle, "Not Connected")
    }

    func testSourcesTextNamesWhichSourcesAreConnected() {
        XCTAssertEqual(summary(grok: true, cursor: true).sourcesText, "Grok CLI + Cursor")
        XCTAssertEqual(summary(grok: true).sourcesText, "Grok CLI")
        XCTAssertEqual(summary(cursor: true).sourcesText, "Cursor")
        XCTAssertEqual(summary().sourcesText, "No source connected")
    }

    func testPlanPrefersGrokTierOverCursorTier() {
        let both = summary(
            grok: true,
            cursor: true,
            grokPlan: "SuperGrok Heavy",
            cursorPlan: "ultra"
        )
        XCTAssertEqual(both.planLabel, "SuperGrok Heavy")
    }

    func testPlanFallsBackToCursorTierTitleCased() {
        XCTAssertEqual(summary(cursor: true, cursorPlan: "ultra").planLabel, "Ultra")
        XCTAssertEqual(summary(cursor: true, cursorPlan: "Ultra Plus").planLabel, "Ultra Plus")
    }

    func testPlanIgnoresDisconnectedSourcesAndEmptyTokens() {
        XCTAssertNil(summary(grok: false, grokPlan: "SuperGrok").planLabel)
        XCTAssertEqual(
            summary(grok: false, cursor: true, grokPlan: "SuperGrok", cursorPlan: "pro").planLabel,
            "Pro"
        )
        XCTAssertNil(summary(grok: true, grokPlan: "").planLabel)
        XCTAssertEqual(summary(grok: true, cursor: true, grokPlan: "", cursorPlan: "pro").planLabel, "Pro")
    }
}
