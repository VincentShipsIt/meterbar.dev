import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class QuotaEventDeliveryTests: XCTestCase {
    func testLocalHookUsesLiteralArgumentsAndASecretFreeFixedEnvironment() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaEventDeliveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let runner = QuotaEventLocalHookRunner(
            runner: WakeEventHookRunner(
                logger: WakeRunLogger(directory: tempDirectory.appendingPathComponent("logs", isDirectory: true))
            )
        )
        let result = await runner.run(
            configuration: configuration(
                executable: "/usr/bin/env",
                arguments: []
            ),
            payload: payload()
        )
        let output = try XCTUnwrap(String(bytes: result.stdoutCapture, encoding: .utf8))

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(output.contains("METERBAR_EVENT=critical"))
        XCTAssertTrue(output.contains("METERBAR_PROVIDER=Cursor"))
        XCTAssertTrue(output.contains("METERBAR_ACCOUNT_ID=account-id"))
        XCTAssertTrue(output.contains("METERBAR_ACCOUNT_NAME=Work"))
        XCTAssertTrue(output.contains("METERBAR_WINDOW=session"))
        XCTAssertTrue(output.contains("METERBAR_PERCENTAGE=91"))
        XCTAssertTrue(output.contains("METERBAR_BAND=critical"))
        XCTAssertFalse(output.contains("CLAUDE_CONFIG_DIR"))
        XCTAssertFalse(output.contains("CODEX_HOME"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("api_key"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("token="))
    }

    func testOneDeliveryFailureDoesNotBlockOtherChannelsOrLaterEvents() async {
        let engine = QuotaEventDeliveryEngine(handlers: QuotaEventDeliveryHandlers(
            local: { _, _ in .failed("Local hook timed out.") },
            webhook: { _, _ in .succeeded }
        ))
        let first = payload()
        let second = QuotaEventPayload(
            provider: first.provider,
            account: first.account,
            event: .exhausted,
            window: .weekly,
            percentage: 100,
            band: .exhausted,
            timestamp: first.timestamp.addingTimeInterval(1)
        )

        let diagnostics = await engine.deliver(
            payloads: [first, second],
            configuration: configuration(
                executable: "/usr/bin/false",
                arguments: [],
                webhookURL: "https://hooks.example.com/meterbar"
            )
        )

        XCTAssertEqual(diagnostics.count, 4)
        XCTAssertEqual(
            diagnostics.filter { $0.channel == .local && !$0.succeeded }.count,
            2
        )
        XCTAssertEqual(
            diagnostics.filter { $0.channel == .webhook && $0.succeeded }.count,
            2
        )
        XCTAssertEqual(Set(diagnostics.map(\.event)), [.critical, .exhausted])
    }

    private func payload() -> QuotaEventPayload {
        QuotaEventPayload(
            provider: .cursor,
            account: QuotaEventAccount(id: "account-id", name: "Work"),
            event: .critical,
            window: .session,
            percentage: 91,
            band: .critical,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func configuration(
        executable: String,
        arguments: [String],
        webhookURL: String = ""
    ) -> QuotaEventIntegrationConfiguration {
        QuotaEventIntegrationConfiguration(
            localDeliveryEnabled: true,
            localExecutablePath: executable,
            localArguments: arguments,
            webhookDeliveryEnabled: !webhookURL.isEmpty,
            webhookURLString: webhookURL,
            enabledQuotaEvents: [.critical, .exhausted],
            enabledProviders: [.cursor],
            enabledAccounts: [
                QuotaEventAccountSelection(provider: .cursor, accountID: "account-id"),
            ],
            enabledWakeEvents: []
        )
    }
}
