import XCTest
import MeterBarShared
@testable import MeterBar

final class ServiceTypeTests: XCTestCase {
    func testRawValues() {
        XCTAssertEqual(ServiceType.claudeCode.rawValue, "Claude Code")
        XCTAssertEqual(ServiceType.codexCli.rawValue, "Codex CLI")
        XCTAssertEqual(ServiceType.cursor.rawValue, "Cursor")
        XCTAssertEqual(ServiceType.openRouter.rawValue, "OpenRouter")
        XCTAssertEqual(ServiceType.grok.rawValue, "Grok")
    }

    func testDisplayNames() {
        XCTAssertEqual(ServiceType.claudeCode.displayName, "Claude Code")
        XCTAssertEqual(ServiceType.codexCli.displayName, "OpenAI Codex")
        XCTAssertEqual(ServiceType.cursor.displayName, "Cursor")
        XCTAssertEqual(ServiceType.openRouter.displayName, "OpenRouter")
        XCTAssertEqual(ServiceType.grok.displayName, "Grok")
    }

    func testIconNames() {
        XCTAssertEqual(ServiceType.claudeCode.iconName, "terminal")
        XCTAssertEqual(ServiceType.codexCli.iconName, "terminal.fill")
        XCTAssertEqual(ServiceType.cursor.iconName, "cursorarrow.click")
        XCTAssertEqual(ServiceType.openRouter.iconName, "point.3.connected.trianglepath.dotted")
        XCTAssertEqual(ServiceType.grok.iconName, "bolt.fill")
    }

    func testIdProperty() {
        XCTAssertEqual(ServiceType.claudeCode.id, "Claude Code")
        XCTAssertEqual(ServiceType.codexCli.id, "Codex CLI")
        XCTAssertEqual(ServiceType.cursor.id, "Cursor")
        XCTAssertEqual(ServiceType.openRouter.id, "OpenRouter")
        XCTAssertEqual(ServiceType.grok.id, "Grok")
    }

    /// The compact brand form, for places where the full product name would
    /// crowd the layout: chart legends, popover provider cards, "Add account"
    /// sheets. It is a second *name*, not a second source of truth — the views
    /// that used to spell these out inline (three separate switches over the
    /// same five cases) now read them from here.
    func testShortNames() {
        XCTAssertEqual(ServiceType.claudeCode.shortName, "Claude")
        XCTAssertEqual(ServiceType.codexCli.shortName, "Codex")
        XCTAssertEqual(ServiceType.cursor.shortName, "Cursor")
        XCTAssertEqual(ServiceType.openRouter.shortName, "OpenRouter")
        XCTAssertEqual(ServiceType.grok.shortName, "Grok")
    }

    /// Both names must exist and be usable for every case, including any added
    /// later — an empty label renders as a blank row rather than failing loudly.
    func testEveryServiceHasBothNames() {
        for service in ServiceType.allCases {
            XCTAssertFalse(service.displayName.isEmpty, "\(service) has no display name")
            XCTAssertFalse(service.shortName.isEmpty, "\(service) has no short name")
            XCTAssertFalse(
                service.shortName.count > service.displayName.count,
                "\(service): the short name must not be longer than the full one"
            )
        }
    }

    func testAllCasesCount() {
        XCTAssertEqual(ServiceType.allCases.count, 5)
    }

    func testCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for service in ServiceType.allCases {
            let encoded = try encoder.encode(service)
            let decoded = try decoder.decode(ServiceType.self, from: encoded)
            XCTAssertEqual(service, decoded)
        }
    }

    func testDecodingFromRawValue() throws {
        let decoder = JSONDecoder()

        let claudeCodeJSON = "\"Claude Code\"".data(using: .utf8)!
        let claudeCode = try decoder.decode(ServiceType.self, from: claudeCodeJSON)
        XCTAssertEqual(claudeCode, .claudeCode)

        let cursorJSON = "\"Cursor\"".data(using: .utf8)!
        let cursor = try decoder.decode(ServiceType.self, from: cursorJSON)
        XCTAssertEqual(cursor, .cursor)
    }

    // Centralized rule (popover, dashboard, widget, and notification copy all
    // route through this): Claude Code's third quota window is model-scoped —
    // it echoes the parsed model label, falling back to "Model" when absent,
    // and is never a hardcoded model name. Every other provider shows
    // "Code Review" regardless of any label.
    func testCodeReviewQuotaTitle() {
        XCTAssertEqual(ServiceType.claudeCode.codeReviewQuotaTitle(modelLimitLabel: "Fable"), "Fable")
        XCTAssertEqual(ServiceType.claudeCode.codeReviewQuotaTitle(modelLimitLabel: "Sonnet"), "Sonnet")
        XCTAssertEqual(ServiceType.claudeCode.codeReviewQuotaTitle(modelLimitLabel: nil), "Model")
        XCTAssertEqual(ServiceType.cursor.codeReviewQuotaTitle(modelLimitLabel: nil), "On-demand")
        for service in ServiceType.allCases where service != .claudeCode && service != .cursor {
            XCTAssertEqual(service.codeReviewQuotaTitle(modelLimitLabel: "Fable"), "Code Review")
            XCTAssertEqual(service.codeReviewQuotaTitle(modelLimitLabel: nil), "Code Review")
        }
    }

    // The long quota window is not weekly for every provider: OpenRouter's is a
    // credit balance and Cursor's resets with the monthly billing cycle, so the
    // shared title must not call either one "Weekly".
    func testWeeklyQuotaTitle() {
        XCTAssertEqual(ServiceType.openRouter.weeklyQuotaTitle, "Account credits")
        XCTAssertEqual(ServiceType.cursor.weeklyQuotaTitle, "Monthly")
        XCTAssertEqual(
            ServiceType.cursor.weeklyQuotaTitle(limitTotal: ServiceType.cursorIncludedPoolTotal),
            "Other Models"
        )
        XCTAssertEqual(ServiceType.cursor.weeklyQuotaTitle(limitTotal: 500), "Monthly")
        for service in ServiceType.allCases where service != .openRouter && service != .cursor {
            XCTAssertEqual(service.weeklyQuotaTitle, "Weekly")
        }
    }

    func testSessionQuotaTitle() {
        XCTAssertEqual(ServiceType.openRouter.sessionQuotaTitle(limitTotal: nil), "Key limit")
        XCTAssertEqual(ServiceType.cursor.sessionQuotaTitle(limitTotal: 20), "Session")
        XCTAssertEqual(
            ServiceType.cursor.sessionQuotaTitle(limitTotal: ServiceType.cursorIncludedPoolTotal),
            "Cursor Models"
        )
        XCTAssertEqual(ServiceType.claudeCode.sessionQuotaTitle(limitTotal: 100), "Session")
    }
}
