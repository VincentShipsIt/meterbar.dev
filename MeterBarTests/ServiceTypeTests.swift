import XCTest
import MeterBarShared
@testable import MeterBar

final class ServiceTypeTests: XCTestCase {
    func testRawValues() {
        XCTAssertEqual(ServiceType.claudeCode.rawValue, "Claude Code")
        XCTAssertEqual(ServiceType.codexCli.rawValue, "Codex CLI")
        XCTAssertEqual(ServiceType.xai.rawValue, "xAI")
        XCTAssertEqual(ServiceType.openRouter.rawValue, "OpenRouter")
    }

    func testDisplayNames() {
        XCTAssertEqual(ServiceType.claudeCode.displayName, "Claude Code")
        XCTAssertEqual(ServiceType.codexCli.displayName, "OpenAI Codex")
        XCTAssertEqual(ServiceType.xai.displayName, "xAI")
        XCTAssertEqual(ServiceType.openRouter.displayName, "OpenRouter")
    }

    func testIconNames() {
        XCTAssertEqual(ServiceType.claudeCode.iconName, "terminal")
        XCTAssertEqual(ServiceType.codexCli.iconName, "terminal.fill")
        XCTAssertEqual(ServiceType.xai.iconName, "bolt.fill")
        XCTAssertEqual(ServiceType.openRouter.iconName, "point.3.connected.trianglepath.dotted")
    }

    func testIdProperty() {
        XCTAssertEqual(ServiceType.claudeCode.id, "Claude Code")
        XCTAssertEqual(ServiceType.codexCli.id, "Codex CLI")
        XCTAssertEqual(ServiceType.xai.id, "xAI")
        XCTAssertEqual(ServiceType.openRouter.id, "OpenRouter")
    }

    /// The compact brand form, for places where the full product name would
    /// crowd the layout: chart legends, popover provider cards, "Add account"
    /// sheets. It is a second *name*, not a second source of truth — the views
    /// that used to spell these out inline (three separate switches over the
    /// same five cases) now read them from here.
    func testShortNames() {
        XCTAssertEqual(ServiceType.claudeCode.shortName, "Claude")
        XCTAssertEqual(ServiceType.codexCli.shortName, "Codex")
        XCTAssertEqual(ServiceType.xai.shortName, "xAI")
        XCTAssertEqual(ServiceType.openRouter.shortName, "OpenRouter")
        XCTAssertEqual(ServiceType.kimiCode.displayName, "Kimi Code")
        XCTAssertEqual(ServiceType.kimiCode.shortName, "Kimi")
        XCTAssertEqual(ServiceType.zaiCodingPlan.displayName, "Z.ai GLM Coding Plan")
        XCTAssertEqual(ServiceType.zaiCodingPlan.shortName, "Z.ai")
        XCTAssertEqual(ServiceType.githubCopilot.displayName, "GitHub Copilot")
        XCTAssertEqual(ServiceType.githubCopilot.shortName, "Copilot")
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
        XCTAssertEqual(ServiceType.allCases.count, 9)
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

        let xaiJSON = "\"xAI\"".data(using: .utf8)!
        XCTAssertEqual(try decoder.decode(ServiceType.self, from: xaiJSON), .xai)
    }

    /// Caches, visibility, widget configuration and iCloud payloads written
    /// before the Grok/Cursor merge carry the old raw values; they must keep
    /// decoding, and both land on the one xAI provider.
    func testLegacyGrokAndCursorRawValuesDecodeToXAI() throws {
        let decoder = JSONDecoder()
        for legacy in ["Grok", "Cursor"] {
            let data = Data("\"\(legacy)\"".utf8)
            XCTAssertEqual(try decoder.decode(ServiceType.self, from: data), .xai, legacy)
            XCTAssertEqual(ServiceType(rawValue: legacy), .xai, legacy)
        }
        XCTAssertNil(ServiceType(rawValue: "Nope"))
    }

    /// Encoding always writes the new canonical value, never a legacy one.
    func testEncodingWritesTheCanonicalRawValue() throws {
        let data = try JSONEncoder().encode(ServiceType.xai)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"xAI\"")
    }

    /// Dictionaries keyed by `ServiceType` encode as `[String, Value]` arrays;
    /// a legacy key must still decode rather than fail the whole payload.
    func testLegacyRawValueDecodesAsDictionaryKey() throws {
        let json = Data(#"["Grok", 1]"#.utf8)
        let decoded = try JSONDecoder().decode([ServiceType: Int].self, from: json)
        XCTAssertEqual(decoded[.xai], 1)
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
        XCTAssertEqual(ServiceType.xai.codeReviewQuotaTitle(modelLimitLabel: nil), "On-demand")
        for service in ServiceType.allCases where service != .claudeCode && service != .xai {
            XCTAssertEqual(service.codeReviewQuotaTitle(modelLimitLabel: "Fable"), "Code Review")
            XCTAssertEqual(service.codeReviewQuotaTitle(modelLimitLabel: nil), "Code Review")
        }
    }

    // The long quota window is not weekly for every provider: OpenRouter's is a
    // credit balance, so the shared title must not call it "Weekly". xAI's
    // shared pool is weekly, like every other provider's long window.
    func testWeeklyQuotaTitle() {
        XCTAssertEqual(ServiceType.openRouter.weeklyQuotaTitle, "Account credits")
        XCTAssertEqual(ServiceType.claudePlatform.weeklyQuotaTitle, "Account credits")
        for service in ServiceType.allCases
        where service != .openRouter && service != .claudePlatform {
            XCTAssertEqual(service.weeklyQuotaTitle, "Weekly")
        }
    }

    func testSessionQuotaTitle() {
        XCTAssertEqual(ServiceType.openRouter.sessionQuotaTitle(limitTotal: nil), "Key limit")
        XCTAssertEqual(ServiceType.xai.sessionQuotaTitle(limitTotal: 20), "Session")
        XCTAssertEqual(ServiceType.xai.sessionQuotaTitle(limitTotal: ServiceType.xaiPercentPoolTotal), "Session")
        XCTAssertEqual(ServiceType.claudeCode.sessionQuotaTitle(limitTotal: 100), "Session")
    }

    /// A monthly (or billing) allowance in the weekly slot must never be
    /// titled Weekly.
    func testXAIWeeklySlotHonorsReportedPeriodKind() {
        XCTAssertEqual(
            ServiceType.xai.weeklyQuotaTitle(limitTotal: 100, periodKind: .monthly),
            "Monthly"
        )
        XCTAssertEqual(
            ServiceType.xai.weeklyQuotaTitle(limitTotal: 100, periodKind: .billing),
            "Billing cycle"
        )
        XCTAssertEqual(
            ServiceType.xai.weeklyQuotaTitle(limitTotal: 100, periodKind: .weekly),
            "Weekly"
        )
        XCTAssertEqual(
            ServiceType.xai.weeklyQuotaTitle(limitTotal: 100, periodKind: .unknown),
            "Quota"
        )
        XCTAssertEqual(
            ServiceType.xai.sessionQuotaTitle(limitTotal: 100, periodKind: .session),
            "Session"
        )
        XCTAssertEqual(
            ServiceType.xai.additionalQuotaTitleKey(
                for: UsageLimit(used: 10, total: 100, resetTime: nil, periodKind: .daily)
            ),
            .daily
        )
    }

    /// Legacy Cursor accounts keep their monthly pools as labelled additional
    /// limits; the exact labels route back to the localized titles, any other
    /// label stays provider data.
    func testLegacyCursorPoolLabelsRouteToTheirLocalizedTitles() {
        let models = UsageLimit(
            used: 20, total: 100, resetTime: nil, periodKind: .monthly,
            label: ServiceType.legacyCursorModelsLabel
        )
        let other = UsageLimit(
            used: 30, total: 100, resetTime: nil, periodKind: .monthly,
            label: ServiceType.legacyOtherModelsLabel
        )
        XCTAssertEqual(ServiceType.xai.additionalQuotaTitleKey(for: models), .cursorModels)
        XCTAssertEqual(ServiceType.xai.additionalQuotaTitleKey(for: other), .otherModels)
        XCTAssertEqual(ServiceType.xai.additionalQuotaTitleKey(for: models).englishTitle, "Cursor Models")
        XCTAssertEqual(ServiceType.xai.additionalQuotaTitleKey(for: other).englishTitle, "Other Models")
    }

    func testOtherAdditionalLabelsStayVerbatimAndOtherProvidersDoNotRemapLegacyLabels() {
        let custom = UsageLimit(used: 1, total: 10, resetTime: nil, label: "Grok Imagine")
        XCTAssertEqual(ServiceType.xai.additionalQuotaTitleKey(for: custom), .model(label: "Grok Imagine"))
        let legacy = UsageLimit(used: 1, total: 10, resetTime: nil, label: ServiceType.legacyCursorModelsLabel)
        XCTAssertEqual(
            ServiceType.codexCli.additionalQuotaTitleKey(for: legacy),
            .model(label: ServiceType.legacyCursorModelsLabel)
        )
    }

    func testIsXAIPercentPool() {
        XCTAssertTrue(ServiceType.isXAIPercentPool(total: 100))
        XCTAssertFalse(ServiceType.isXAIPercentPool(total: 500))
    }

    /// A non-percent xAI total in a monthly slot falls through to the
    /// periodKind override.
    func testXAIPeriodKindOverridesApplyToNonPercentTotals() {
        XCTAssertEqual(
            ServiceType.xai.weeklyQuotaTitleKey(limitTotal: 500, periodKind: .monthly),
            .monthly
        )
    }

    /// OpenRouter's quota is a running credit balance, never period-based, so
    /// the periodKind override must never eclipse its key-limit / account-credits
    /// titles either.
    func testOpenRouterOutranksPeriodKindOverride() {
        XCTAssertEqual(
            ServiceType.openRouter.sessionQuotaTitleKey(limitTotal: nil, periodKind: .monthly),
            .keyLimit
        )
        XCTAssertEqual(
            ServiceType.openRouter.weeklyQuotaTitleKey(limitTotal: nil, periodKind: .monthly),
            .accountCredits
        )
    }
}
