import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Per-account Codex auth state (issue #304).
///
/// Codex connection state used to be one shared `hasAccess` flag probed from the
/// default sentinel only, so a signed-in custom `CODEX_HOME` profile still read
/// "Not connected" — and a probe of a custom profile could overwrite the default
/// profile's flag. Auth is now tracked per account, keyed by account id.
final class CodexAccountAccessTests: XCTestCase {
    // MARK: - Projection

    func testProjectionFallsBackToSharedFlagOnlyForTheDefaultSentinel() {
        XCTAssertTrue(
            CodexAccountAccessProjection.isAuthenticated(
                account: .defaultAccount,
                accountAccess: [:],
                defaultHasAccess: true
            )
        )
        XCTAssertFalse(
            CodexAccountAccessProjection.isAuthenticated(
                account: custom(),
                accountAccess: [:],
                defaultHasAccess: true
            )
        )
    }

    func testProjectionPrefersTheRecordedPerAccountResultOverTheSharedFlag() {
        let account = custom()

        XCTAssertTrue(
            CodexAccountAccessProjection.isAuthenticated(
                account: account,
                accountAccess: [account.id: true],
                defaultHasAccess: false
            )
        )
        XCTAssertFalse(
            CodexAccountAccessProjection.isAuthenticated(
                account: .defaultAccount,
                accountAccess: [CodexAccount.defaultID: false],
                defaultHasAccess: true
            )
        )
    }

    /// The Providers page Status row and the settings sidebar health dot both
    /// read this: a connected custom profile keeps Codex "connected" even when
    /// the default sentinel is disabled or logged out.
    func testProviderAccessIsTrueWhenAnyEnabledProfileIsAuthenticated() {
        let account = custom()

        XCTAssertTrue(
            CodexAccountAccessProjection.hasAnyAccess(
                accounts: [account],
                accountAccess: [account.id: true],
                defaultHasAccess: false
            )
        )
        XCTAssertFalse(
            CodexAccountAccessProjection.hasAnyAccess(
                accounts: [account],
                accountAccess: [account.id: false],
                defaultHasAccess: true
            )
        )
        XCTAssertFalse(
            CodexAccountAccessProjection.hasAnyAccess(
                accounts: [],
                accountAccess: [:],
                defaultHasAccess: true
            )
        )
    }

    // MARK: - Service bookkeeping

    func testCheckAccessRecordsEachProfileSeparately() {
        let work = custom()
        let service = makeService(authenticatedAccountIDs: [work.id])

        service.checkAccess(account: .defaultAccount)
        service.checkAccess(account: work)

        XCTAssertEqual(service.accountAccess[CodexAccount.defaultID], .some(false))
        XCTAssertEqual(service.accountAccess[work.id], .some(true))
        XCTAssertTrue(service.isAuthenticated(account: work))
        XCTAssertFalse(service.isAuthenticated(account: .defaultAccount))
    }

    /// A custom-profile probe must never publish into the shared default flag;
    /// that flag still drives the default profile's own presentation.
    func testCustomProfileProbeLeavesTheSharedDefaultFlagAlone() {
        let work = custom()
        let service = makeService(authenticatedAccountIDs: [CodexAccount.defaultID])

        service.checkAccess(account: .defaultAccount)
        XCTAssertTrue(service.hasAccess)

        service.checkAccess(account: work)

        XCTAssertTrue(service.hasAccess)
        XCTAssertEqual(service.accountAccess[work.id], .some(false))
    }

    func testAsyncProbeRecordsTheResultForLaterReads() async {
        let work = custom()
        let service = makeService(authenticatedAccountIDs: [work.id])

        let connected = await service.canAccess(account: work)

        XCTAssertTrue(connected)
        XCTAssertEqual(service.accountAccess[work.id], .some(true))
    }

    /// Regression for the 1.8.3 Settings → Codex crash: the settings row probes
    /// through a stored `(CodexAccount) async -> Bool` closure, so the account
    /// reaches `canAccess` @in_guaranteed via a nonisolated(nonsending)
    /// reabstraction thunk, and that indirect argument did not survive the
    /// probe's suspension point. This drives the exact same thunked path; the
    /// service must record the result without touching the argument after resume.
    func testProbeThroughStoredRowClosureRecordsPerAccountResult() async {
        let work = custom()
        let service = makeService(authenticatedAccountIDs: [work.id])
        let connectionCheck: (CodexAccount) async -> Bool = {
            await service.canAccess(account: $0)
        }

        let workConnected = await connectionCheck(work)
        let defaultConnected = await connectionCheck(.defaultAccount)

        XCTAssertTrue(workConnected)
        XCTAssertFalse(defaultConnected)
        XCTAssertEqual(service.accountAccess[work.id], .some(true))
        XCTAssertEqual(service.accountAccess[CodexAccount.defaultID], .some(false))
        XCTAssertFalse(service.hasAccess)
    }

    /// `canAccess` must stay `nonisolated`. A main-actor-isolated `async` probe
    /// hops to the main actor *before its body runs*, and the caller-owned
    /// `@in_guaranteed` account address does not survive that entry hop — that
    /// is the codegen that segfaulted in both 1.8.3 and 1.8.31. Probing from a
    /// detached task pins the requirement: this only completes without a
    /// deadlock-free main hop if the callee starts on the caller's executor and
    /// re-enters the main actor explicitly to record.
    func testProbeFromOffTheMainActorThroughStoredClosureStillRecords() async {
        let work = custom()
        let service = makeService(authenticatedAccountIDs: [work.id])
        let connectionCheck: @Sendable (CodexAccount) async -> Bool = {
            await service.canAccess(account: $0)
        }

        let connected = await Task.detached { await connectionCheck(work) }.value

        XCTAssertTrue(connected)
        XCTAssertEqual(service.accountAccess[work.id], .some(true))
    }

    func testProviderAccessSpansEveryEnabledProfile() {
        let work = custom()
        let service = makeService(authenticatedAccountIDs: [work.id])

        service.checkAccess(account: .defaultAccount)
        service.checkAccess(account: work)

        XCTAssertFalse(service.hasAccess)
        XCTAssertTrue(service.hasAccess(in: [.defaultAccount, work]))
        XCTAssertFalse(service.hasAccess(in: [.defaultAccount]))
    }

    // MARK: Private

    /// 2100-01-01, so the fixture token never expires mid-suite.
    private let futureExp: TimeInterval = 4_102_444_800

    private func custom(name: String = "Work") -> CodexAccount {
        CodexAccount(id: workAccountID, name: name, homeDirectory: "/tmp/codex-work")
    }

    private let workAccountID = UUID()

    private func makeService(authenticatedAccountIDs: Set<UUID>) -> CodexCliLocalService {
        let token = makeJWT(exp: futureExp)
        return CodexCliLocalService(accountAuthFileDataProvider: { account in
            guard authenticatedAccountIDs.contains(account.id) else { return nil }
            return Self.authFileJSON(accessToken: token)
        })
    }

    nonisolated private static func authFileJSON(accessToken: String) -> Data {
        Data("""
        {
          "OPENAI_API_KEY": null,
          "tokens": {
            "id_token": "\(accessToken)",
            "access_token": "\(accessToken)",
            "refresh_token": "refresh",
            "account_id": "acc_1"
          },
          "last_refresh": "2026-07-01T00:00:00Z"
        }
        """.utf8)
    }

    /// Unsigned JWT (header.payload.signature); only the payload is read.
    private func makeJWT(exp: TimeInterval) -> String {
        let header = base64URL(Data(#"{"alg":"none","typ":"JWT"}"#.utf8))
        let payload = base64URL(Data("{\"exp\":\(Int(exp))}".utf8))
        return "\(header).\(payload).sig"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
