import Foundation
import Security
import XCTest
@testable import MeterBar

/// Read-only login discovery. No test calls `SecItemCopyMatching`.
final class MuseCodeCredentialReaderTests: XCTestCase {
    func testDisabledProviderPerformsNoReads() {
        let harness = ReaderHarness()
        harness.enabled = false
        XCTAssertEqual(harness.read(), .disabled)
        XCTAssertEqual(harness.read().probe, .disabled)
        XCTAssertTrue(harness.loadedPaths.isEmpty)
        XCTAssertTrue(harness.keychainModes.isEmpty)
    }

    func testMissingAuthFileIsNotSignedInWithoutKeychain() {
        let harness = ReaderHarness()
        harness.load = .missing
        XCTAssertEqual(harness.read(), .notSignedIn)
        XCTAssertEqual(harness.read().probe, .notSignedIn)
        XCTAssertEqual(harness.loadedPaths.count, 2)
        XCTAssertTrue(harness.keychainModes.isEmpty)
    }

    func testInlineTokenWinsAndSkipsKeychain() {
        let harness = ReaderHarness()
        harness.load = .data(Self.meta(#""access_token":"dca:inline-token","mechanism":"oauth","subs_active":true"#))
        harness.outcome = .value(Data(Self.keychainSecret.utf8))
        XCTAssertEqual(harness.read(), .token("dca:inline-token"))
        XCTAssertEqual(harness.read().probe, .ready)
        XCTAssertTrue(harness.keychainModes.isEmpty)
        XCTAssertFalse(String(describing: harness.read()).contains(Self.email))
    }

    func testNonDeviceCodeInlineTokenDoesNotFallThrough() {
        let harness = ReaderHarness()
        harness.load = .data(Self.meta(#""access_token":"oauth-not-device-code","mechanism":"oauth""#))
        harness.outcome = .value(Data(Self.keychainSecret.utf8))
        XCTAssertEqual(harness.read(), .rejectedToken)
        XCTAssertTrue(harness.keychainModes.isEmpty)
    }

    func testBlankOrPrefixOnlyInlineTokenIsRejected() {
        for token in ["", "dca:", "  dca:  "] {
            let harness = ReaderHarness()
            harness.load = .data(Self.meta(#""access_token":"\#(token)","mechanism":"oauth""#))
            harness.outcome = .value(Data(Self.keychainSecret.utf8))
            XCTAssertEqual(harness.read(), .rejectedToken, token)
            XCTAssertTrue(harness.keychainModes.isEmpty)
        }
        let typed = ReaderHarness()
        typed.load = .data(Self.meta(#""access_token":1,"mechanism":"oauth""#))
        typed.outcome = .value(Data(Self.keychainSecret.utf8))
        XCTAssertEqual(typed.read(), .rejectedToken)
        XCTAssertTrue(typed.keychainModes.isEmpty)
    }

    func testKeychainPayloadUsesAccessTokenAndIgnoresAPIKey() {
        let harness = ReaderHarness()
        harness.load = .data(Self.meta(#""mechanism":"oauth","subs_active":true"#))
        harness.outcome = .value(Data(Self.keychainSecret.utf8))
        XCTAssertEqual(harness.read(), .token("dca:keychain-token"))
        XCTAssertEqual(harness.keychainModes, [.background])
        XCTAssertFalse(String(describing: harness.read()).contains("mk-inference-secret-value"))
    }

    func testKeychainAPIKeyAloneIsRejected() {
        let secret = #"{"api_key":"dca:do-not-use-inference-key","secret_schema_version":1}"#
        let harness = ReaderHarness()
        harness.load = .data(Self.meta(#""mechanism":"oauth","subs_active":true"#))
        harness.outcome = .value(Data(secret.utf8))
        XCTAssertEqual(harness.read(), .needsConnect)
    }

    func testNonDeviceCodeKeychainTokenIsRejected() {
        let harness = ReaderHarness()
        harness.load = .data(Self.meta(#""mechanism":"oauth","subs_active":true"#))
        harness.outcome = .value(Data(#"{"access_token":"ya29.not-muse"}"#.utf8))
        XCTAssertEqual(harness.read(), .rejectedToken)
    }

    func testMissingKeychainItemNeedsConnect() {
        let harness = ReaderHarness()
        harness.load = .data(Self.meta(#""mechanism":"oauth","subs_active":true"#))
        harness.outcome = .notFound
        let result = harness.read()
        XCTAssertEqual(result, .needsConnect)
        XCTAssertEqual(result.probe, .needsConnect)
    }

    func testInactiveSubscriptionSkipsKeychain() {
        let harness = ReaderHarness()
        harness.load = .data(Self.meta(#""mechanism":"oauth","subs_active":false"#))
        harness.outcome = .value(Data(Self.keychainSecret.utf8))
        XCTAssertEqual(harness.read(), .noSubscription)
        XCTAssertEqual(harness.read().probe, .noSubscription)
        XCTAssertTrue(harness.keychainModes.isEmpty)
    }

    func testWrongTypedSubscriptionFlagStillReadsKeychain() {
        let harness = ReaderHarness()
        harness.load = .data(Self.meta(#""mechanism":"oauth","subs_active":1"#))
        harness.outcome = .value(Data(Self.keychainSecret.utf8))
        XCTAssertEqual(harness.read(), .token("dca:keychain-token"))
        XCTAssertEqual(harness.keychainModes, [.background])
    }

    func testInteractionRequiredNeedsKeychainAccessAndCancelNeedsConnect() {
        let blocked = ReaderHarness()
        blocked.load = .data(Self.meta(#""mechanism":"OAuth","subs_active":true"#))
        blocked.outcome = .interactionRequired
        XCTAssertEqual(blocked.read(), .needsKeychainAccess)
        XCTAssertEqual(blocked.keychainModes, [.background])

        let cancelled = ReaderHarness()
        cancelled.load = .data(Self.meta(#""mechanism":"oauth","subs_active":true"#))
        cancelled.outcome = .denied
        XCTAssertEqual(cancelled.read(), .needsConnect)
    }

    func testKeychainFailureIsUnreadable() {
        let harness = ReaderHarness()
        harness.load = .data(Self.meta(#""mechanism":"oauth","subs_active":true"#))
        harness.outcome = .failure(errSecAuthFailed)
        XCTAssertEqual(harness.read(), .unreadable)
    }

    func testMissingProviderOrNonOAuthIsNotSignedIn() {
        let absent = ReaderHarness()
        absent.load = .data(Data(#"{"email":"\#(Self.email)"}"#.utf8))
        XCTAssertEqual(absent.read(), .notSignedIn)
        XCTAssertTrue(absent.keychainModes.isEmpty)

        let other = ReaderHarness()
        other.load = .data(Self.meta(#""mechanism":"password","subs_active":true"#))
        other.outcome = .value(Data(Self.keychainSecret.utf8))
        XCTAssertEqual(other.read(), .notSignedIn)
        XCTAssertTrue(other.keychainModes.isEmpty)
    }

    func testUnreadableFileSkipsKeychain() {
        let harness = ReaderHarness()
        harness.load = .unreadable
        harness.outcome = .value(Data(Self.keychainSecret.utf8))
        XCTAssertEqual(harness.read(), .unreadable)
        XCTAssertTrue(harness.keychainModes.isEmpty)
    }

    func testAuthPathOverrideIsWhatGetsLoaded() {
        let harness = ReaderHarness()
        harness.environment = ["MUSE_AUTH_PATH": " ~/muse-auth.json "]
        harness.home = "/Users/tester"
        harness.load = .missing
        _ = harness.read()
        XCTAssertEqual(harness.loadedPaths, ["/Users/tester/muse-auth.json"])
    }

    func testBackgroundQueryRefusesAuthenticationUI() {
        let background = MuseCodeKeychainQuery.dictionary(mode: .background)
        XCTAssertEqual(background[kSecAttrService as String] as? String, MuseCodeKeychainQuery.service)
        XCTAssertEqual(background[kSecAttrAccount as String] as? String, MuseCodeKeychainQuery.account)
        XCTAssertEqual(
            background[kSecUseAuthenticationUI as String] as? String,
            kSecUseAuthenticationUIFail as String
        )
        let interactive = MuseCodeKeychainQuery.dictionary(mode: .interactive)
        XCTAssertNil(interactive[kSecUseAuthenticationUI as String])
    }

    /// The dictionary flag alone does not suppress the legacy ACL dialog.
    /// Background reads also force the process interaction flag off for the copy.
    func testBackgroundReadDisablesLegacyUserInteraction() {
        let gate = LegacyKeychainInteractionGate()
        var sawFailFlag = false
        var interactionAllowed: Bool?
        let outcome = MuseCodeKeychainQuery.read(mode: .background, gate: gate) { query in
            let dictionary = query as NSDictionary
            sawFailFlag = dictionary[kSecUseAuthenticationUI as String] as? String
                == kSecUseAuthenticationUIFail as String
            interactionAllowed = LegacyKeychainInteractionGate.currentUserInteractionAllowed()
            return (errSecItemNotFound, nil)
        }
        XCTAssertEqual(outcome, .notFound)
        XCTAssertTrue(sawFailFlag)
        XCTAssertEqual(interactionAllowed, false)

        var interactiveAllowed: Bool?
        _ = MuseCodeKeychainQuery.read(mode: .interactive, gate: gate) { _ in
            interactiveAllowed = LegacyKeychainInteractionGate.currentUserInteractionAllowed()
            return (errSecItemNotFound, nil)
        }
        XCTAssertEqual(interactiveAllowed, true)
    }

    func testLoadAuthFileRejectsASymlinkAndReadsARegularFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let regular = directory.appendingPathComponent("auth.json")
        let payload = Data(#"{"ok":true}"#.utf8)
        try payload.write(to: regular)
        XCTAssertEqual(MuseCodeCredentialReader.loadAuthFile(at: regular.path), .data(payload))

        let link = directory.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        XCTAssertEqual(MuseCodeCredentialReader.loadAuthFile(at: link.path), .unreadable)
        XCTAssertEqual(
            MuseCodeCredentialReader.loadAuthFile(at: directory.appendingPathComponent("missing.json").path),
            .missing
        )
        XCTAssertEqual(MuseCodeCredentialReader.loadAuthFile(at: directory.path), .unreadable)

        let oversized = directory.appendingPathComponent("big.json")
        let extra = MuseCodeCredentialReader.maximumFileSize + 1
        try Data(repeating: 0x61, count: extra).write(to: oversized)
        XCTAssertEqual(MuseCodeCredentialReader.loadAuthFile(at: oversized.path), .unreadable)
    }

    private static let email = "person@example.invalid"
    private static let keychainSecret =
        #"{"access_token":"dca:keychain-token","api_key":"mk-inference-secret-value","secret_schema_version":1}"#

    private static func meta(_ fields: String) -> Data {
        Data(#"{"email":"\#(email)","providers":{"meta":{\#(fields)}}}"#.utf8)
    }
}

private nonisolated final class ReaderHarness: @unchecked Sendable {
    var enabled = true
    var environment = ["MUSE_AUTH_PATH": "/tmp/muse-auth.json"]
    var home = "/Users/tester"
    var mode = ClaudeKeychainAccessMode.background
    var load = MuseCodeAuthLoad.missing
    var outcome = ClaudeKeychainReadOutcome<Data>.notFound
    private(set) var loadedPaths: [String] = []
    private(set) var keychainModes: [ClaudeKeychainAccessMode] = []

    func read() -> MuseCodeCredentialReader.Result {
        MuseCodeCredentialReader.read(
            MuseCodeCredentialReader.Context(
                enabled: enabled,
                environment: environment,
                realHomeDirectory: home,
                accessMode: mode,
                loadAuth: { path in
                    self.loadedPaths.append(path)
                    return self.load
                },
                keychain: { mode in
                    self.keychainModes.append(mode)
                    return self.outcome
                }
            )
        )
    }
}
