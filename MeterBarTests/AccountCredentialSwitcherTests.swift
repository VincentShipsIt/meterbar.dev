import Foundation
import XCTest
@testable import MeterBar

final class AccountCredentialSwitcherTests: XCTestCase {
    func testCoordinatorUsesInjectedCredentialSwitcherAndNeverNeedsKeychainInTests() async throws {
        let preferred = UUID()
        let fallback = UUID()
        let switcher = RecordingCredentialSwitcher()

        try await switcher.switchCredentials(
            provider: .claudeCode,
            from: preferred,
            to: fallback
        )

        let calls = switcher.calls
        XCTAssertEqual(
            calls,
            [AccountCredentialSwitch(provider: .claudeCode, fromAccountID: preferred, toAccountID: fallback)]
        )
    }
}

private final class RecordingCredentialSwitcher: AccountCredentialSwitching {
    private(set) var calls: [AccountCredentialSwitch] = []

    func switchCredentials(provider: AccountFailoverProvider, from: UUID, to: UUID) async throws {
        calls.append(AccountCredentialSwitch(provider: provider, fromAccountID: from, toAccountID: to))
    }
}
