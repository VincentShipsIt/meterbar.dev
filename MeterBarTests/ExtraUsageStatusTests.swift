import XCTest
import MeterBarShared
@testable import MeterBar

final class ExtraUsageStatusTests: XCTestCase {
    // MARK: - ExtraUsageStatus basics

    func testUnknownConstant() {
        XCTAssertEqual(ExtraUsageStatus.unknown.state, .unknown)
        XCTAssertNil(ExtraUsageStatus.unknown.detail)
    }

    func testFormatAmountUSD() {
        XCTAssertEqual(ExtraUsageStatus.formatAmount(5), "$5.00")
        XCTAssertEqual(ExtraUsageStatus.formatAmount(0), "$0.00")
        XCTAssertEqual(ExtraUsageStatus.formatAmount(12.5, currency: "usd"), "$12.50")
    }

    func testFormatAmountNonUSD() {
        XCTAssertEqual(ExtraUsageStatus.formatAmount(5, currency: "EUR"), "5.00 EUR")
    }

    // MARK: - UsageMetrics integration

    func testDefaultExtraUsageIsNil() {
        let metrics = UsageMetrics(service: .codexCli)
        XCTAssertNil(metrics.extraUsage)
    }

    func testWithExtraUsagePreservesIdentityAndLimits() {
        let original = UsageMetrics(
            service: .claudeCode,
            sessionLimit: UsageLimit(used: 10, total: 100, resetTime: nil),
            weeklyLimit: UsageLimit(used: 20, total: 100, resetTime: nil)
        )

        let updated = original.withExtraUsage(ExtraUsageStatus(state: .off))

        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.service, original.service)
        XCTAssertEqual(updated.sessionLimit, original.sessionLimit)
        XCTAssertEqual(updated.weeklyLimit, original.weeklyLimit)
        XCTAssertEqual(updated.lastUpdated, original.lastUpdated)
        XCTAssertEqual(updated.extraUsage?.state, .off)
    }

    func testCodableRoundTripWithExtraUsage() throws {
        let original = UsageMetrics(
            service: .codexCli,
            weeklyLimit: UsageLimit(used: 30, total: 100, resetTime: nil),
            extraUsage: ExtraUsageStatus(state: .on, detail: "$5.00 in credits")
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UsageMetrics.self, from: data)

        XCTAssertEqual(decoded.extraUsage?.state, .on)
        XCTAssertEqual(decoded.extraUsage?.detail, "$5.00 in credits")
    }

    func testDecodingLegacyJSONWithoutExtraUsageYieldsNil() throws {
        // Older cached payloads have no `extraUsage` key; decoding must not fail.
        let legacy = """
        {
            "id": "1B9E9B4A-3B6C-4A9D-9C5E-3A1F2B3C4D5E",
            "service": "Codex CLI",
            "lastUpdated": 770000000
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(UsageMetrics.self, from: legacy)
        XCTAssertNil(decoded.extraUsage)
        XCTAssertEqual(decoded.service, .codexCli)
    }

    // MARK: - Codex mapping

    private func decodeCodex(_ json: String) throws -> CodexCliUsageResponse {
        try JSONDecoder().decode(CodexCliUsageResponse.self, from: json.data(using: .utf8)!)
    }

    func testCodexNoCreditsIsUnknown() throws {
        // Absence of the credits object is absence of information, NOT proof that overage is
        // off — it must never render a confident "Off".
        let response = try decodeCodex(#"{"plan_type":"pro"}"#)
        XCTAssertEqual(response.extraUsageStatus.state, .unknown)
        XCTAssertNil(response.extraUsageStatus.detail)
    }

    func testCodexExplicitEmptyCreditsIsOff() throws {
        // Credits object present and explicitly empty is authoritative evidence of "Off".
        let response = try decodeCodex(#"""
        {"plan_type":"pro","credits":{"has_credits":false,"unlimited":false,"overage_limit_reached":false,"balance":"0"},"spend_control":{"reached":false,"individual_limit":null}}
        """#)
        XCTAssertEqual(response.extraUsageStatus.state, .off)
    }

    func testCodexOverageLimitReachedIsOn() throws {
        let response = try decodeCodex(#"""
        {"plan_type":"pro","credits":{"has_credits":false,"unlimited":false,"overage_limit_reached":true,"balance":"0"}}
        """#)
        XCTAssertEqual(response.extraUsageStatus.state, .on)
    }

    func testCodexSpendControlCapWithoutCreditsIsOn() throws {
        // A configured overage cap means overage billing is set up even with a zero balance.
        let response = try decodeCodex(#"""
        {"plan_type":"pro","credits":{"has_credits":false,"unlimited":false,"balance":"0"},"spend_control":{"reached":false,"individual_limit":50}}
        """#)
        let status = response.extraUsageStatus
        XCTAssertEqual(status.state, .on)
        XCTAssertEqual(status.detail?.contains("$50.00"), true)
    }

    func testCodexUnlimitedIsOn() throws {
        let response = try decodeCodex(#"""
        {"plan_type":"pro","credits":{"has_credits":false,"unlimited":true,"balance":"0"}}
        """#)
        let status = response.extraUsageStatus
        XCTAssertEqual(status.state, .on)
        XCTAssertEqual(status.detail, "Unlimited credits")
    }

    func testCodexPositiveBalanceIsOn() throws {
        let response = try decodeCodex(#"""
        {"plan_type":"pro","credits":{"has_credits":true,"unlimited":false,"balance":"5"}}
        """#)
        let status = response.extraUsageStatus
        XCTAssertEqual(status.state, .on)
        XCTAssertEqual(status.detail?.contains("$5.00"), true)
    }

    func testCodexBalanceAsNumberIsOn() throws {
        let response = try decodeCodex(#"""
        {"plan_type":"pro","credits":{"has_credits":false,"unlimited":false,"balance":7.5}}
        """#)
        let status = response.extraUsageStatus
        XCTAssertEqual(status.state, .on)
        XCTAssertEqual(status.detail?.contains("$7.50"), true)
    }

    func testCodexSpendControlCapAppended() throws {
        let response = try decodeCodex(#"""
        {"plan_type":"pro","credits":{"has_credits":true,"balance":"5"},"spend_control":{"reached":false,"individual_limit":50}}
        """#)
        let status = response.extraUsageStatus
        XCTAssertEqual(status.state, .on)
        XCTAssertEqual(status.detail?.contains("cap $50.00"), true)
    }

    func testCodexSpendControlNullLimitDecodes() throws {
        let response = try decodeCodex(#"""
        {"plan_type":"pro","credits":{"has_credits":true,"balance":"5"},"spend_control":{"reached":false,"individual_limit":null}}
        """#)
        XCTAssertEqual(response.spendControl?.individualLimit, nil)
        XCTAssertEqual(response.extraUsageStatus.state, .on)
    }

    // MARK: - Claude mapping

    private func decodeClaude(_ json: String) throws -> ClaudeCodeUsageResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ClaudeCodeUsageResponse.self, from: json.data(using: .utf8)!)
    }

    private let claudeWindows = #""five_hour":{"utilization":13,"resets_at":"2026-06-19T11:49:59Z"},"seven_day":{"utilization":74,"resets_at":"2026-06-19T19:59:59Z"}"#

    func testClaudeExtraUsageDisabledIsOff() throws {
        let response = try decodeClaude("{\(claudeWindows),\"extra_usage\":{\"is_enabled\":false}}")
        XCTAssertEqual(response.extraUsageStatus.state, .off)
        XCTAssertNil(response.extraUsageStatus.detail)
    }

    func testClaudeExtraUsageEnabledIsOnWithSpendDetail() throws {
        let json = "{\(claudeWindows),\"extra_usage\":{\"is_enabled\":true,\"monthly_limit\":50,\"currency\":\"USD\"},\"spend\":{\"used\":{\"amount_minor\":250,\"currency\":\"USD\",\"exponent\":2},\"enabled\":true}}"
        let status = try decodeClaude(json).extraUsageStatus
        XCTAssertEqual(status.state, .on)
        XCTAssertEqual(status.detail?.contains("$2.50 used"), true)
        XCTAssertEqual(status.detail?.contains("cap $50.00/mo"), true)
    }

    func testClaudeFallsBackToSpendEnabledWhenNoExtraUsage() throws {
        let json = "{\(claudeWindows),\"spend\":{\"enabled\":true,\"used\":{\"amount_minor\":0,\"exponent\":2}}}"
        XCTAssertEqual(try decodeClaude(json).extraUsageStatus.state, .on)
    }

    func testClaudeSpendDisabledWithoutExtraUsageIsUnknown() throws {
        // Only extra_usage.is_enabled authoritatively proves "Off"; spend.enabled==false alone
        // must not produce a false "Off".
        let json = "{\(claudeWindows),\"spend\":{\"enabled\":false,\"used\":{\"amount_minor\":0,\"exponent\":2}}}"
        XCTAssertEqual(try decodeClaude(json).extraUsageStatus.state, .unknown)
    }

    func testClaudeUnknownWhenNoExtraUsageOrSpend() throws {
        let status = try decodeClaude("{\(claudeWindows)}").extraUsageStatus
        XCTAssertEqual(status.state, .unknown)
    }

    func testClaudeMoneyDecodesMinorUnits() throws {
        let json = "{\(claudeWindows),\"spend\":{\"enabled\":true,\"used\":{\"amount_minor\":1299,\"exponent\":2,\"currency\":\"USD\"}}}"
        let status = try decodeClaude(json).extraUsageStatus
        XCTAssertEqual(status.detail?.contains("$12.99 used"), true)
    }
}
