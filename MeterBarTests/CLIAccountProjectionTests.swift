import Foundation
import XCTest
@testable import MeterBar

@MainActor
final class CLIAccountProjectionTests: XCTestCase {
    func testEmptyAuthoritativeArraysDoNotEnableDefaults() {
        XCTAssertTrue(ClaudeCodeAccountStore(accounts: []).enabledAccounts.isEmpty)
        XCTAssertTrue(CodexAccountStore(accounts: []).enabledAccounts.isEmpty)
        XCTAssertTrue(GrokAccountStore(accounts: []).enabledAccounts.isEmpty)
        XCTAssertTrue(OpenRouterAccountStore(accounts: []).enabledAccounts.isEmpty)
    }

    func testCustomOnlyProjectionsRetainOrderAndFlagsWithoutEnablingDefaults() {
        let first = UUID()
        let second = UUID()
        let claude = ClaudeCodeAccountStore(accounts: [
            ClaudeCodeAccount(id: second, name: "Second", configDirectory: "/tmp/second", isEnabled: false),
            ClaudeCodeAccount(id: first, name: "First", configDirectory: "/tmp/first"),
        ])
        let codex = CodexAccountStore(accounts: [
            CodexAccount(id: second, name: "Second", homeDirectory: "/tmp/second", isEnabled: false),
            CodexAccount(id: first, name: "First", homeDirectory: "/tmp/first"),
        ])
        let grok = GrokAccountStore(accounts: [
            GrokAccount(id: second, name: "Second", homeDirectory: "/tmp/second", isEnabled: false),
            GrokAccount(id: first, name: "First", homeDirectory: "/tmp/first"),
        ])
        let openRouter = OpenRouterAccountStore(accounts: [
            OpenRouterAccount(id: second, name: "Second", isEnabled: false),
            OpenRouterAccount(id: first, name: "First"),
        ])
        for ids in [
            claude.accounts.map(\.id),
            codex.accounts.map(\.id),
            grok.accounts.map(\.id),
            openRouter.accounts.map(\.id),
        ] {
            XCTAssertEqual(Array(ids.prefix(2)), [second, first])
        }
        for ids in [
            claude.enabledAccounts.map(\.id),
            codex.enabledAccounts.map(\.id),
            grok.enabledAccounts.map(\.id),
            openRouter.enabledAccounts.map(\.id),
        ] {
            XCTAssertEqual(ids, [first])
        }
    }

    func testExplicitDefaultsPreserveNameAndEnablement() {
        for enabled in [false, true] {
            var claude = ClaudeCodeAccount.defaultAccount
            var codex = CodexAccount.defaultAccount
            var grok = GrokAccount.defaultAccount
            var openRouter = OpenRouterAccount.defaultAccount
            claude.name = "CLI default"
            codex.name = "CLI default"
            grok.name = "CLI default"
            openRouter.name = "CLI default"
            claude.isEnabled = enabled
            codex.isEnabled = enabled
            grok.isEnabled = enabled
            openRouter.isEnabled = enabled
            let stores = [
                ClaudeCodeAccountStore(accounts: [claude]).accounts.map { ($0.name, $0.isEnabled) },
                CodexAccountStore(accounts: [codex]).accounts.map { ($0.name, $0.isEnabled) },
                GrokAccountStore(accounts: [grok]).accounts.map { ($0.name, $0.isEnabled) },
                OpenRouterAccountStore(accounts: [openRouter]).accounts.map { ($0.name, $0.isEnabled) },
            ]
            for accounts in stores {
                XCTAssertEqual(accounts.count, 1)
                XCTAssertEqual(accounts.first?.0, "CLI default")
                XCTAssertEqual(accounts.first?.1, enabled)
            }
        }
    }
}
