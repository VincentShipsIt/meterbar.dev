import Foundation
import XCTest
@testable import MeterBar

@MainActor
final class ClaudeFableSessionTrackerTests: XCTestCase {
    private let accountAID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
    private let accountBID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3))
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private var tempDirectory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeFableSessionTrackerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        suiteName = "ClaudeFableSessionTrackerTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        tempDirectory = nil
        suiteName = nil
        defaults = nil
        try super.tearDownWithError()
    }

    func testSameSourceSessionInTwoProfilesRemainsProfileAttributed() async throws {
        let firstRoot = try makeProjectsDirectory(named: "first")
        let secondRoot = try makeProjectsDirectory(named: "second")
        try writeTranscript(
            to: firstRoot,
            name: "first.jsonl",
            events: [event(sessionID: "shared-session", timestamp: now)]
        )
        try writeTranscript(
            to: secondRoot,
            name: "second.jsonl",
            events: [event(sessionID: "shared-session", timestamp: now)]
        )

        let result = await ClaudeFableSessionScanner().scan(
            accounts: [account(id: accountAID, name: "Alpha"), account(id: accountBID, name: "Beta")],
            projectDirectories: [accountAID: firstRoot, accountBID: secondRoot],
            now: now
        )

        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(Set(result.sessions.map(\.sourceSessionID)), ["shared-session"])
        XCTAssertEqual(Set(result.sessions.map(\.accountID)), [accountAID, accountBID])
        XCTAssertEqual(Set(result.sessions.map(\.id)).count, 2)
    }

    func testDeduplicatesRepeatedEventsAndIgnoresNonFableModels() async throws {
        let root = try makeProjectsDirectory(named: "profile")
        let firstTimestamp = now.addingTimeInterval(-120)
        let latestTimestamp = now.addingTimeInterval(-60)
        try writeTranscript(
            to: root,
            name: "session.jsonl",
            events: [
                event(
                    sessionID: "fable-session",
                    timestamp: firstTimestamp,
                    model: "claude-fable-5-20260701",
                    stopReason: "tool_use"
                ),
                event(
                    sessionID: "fable-session",
                    timestamp: latestTimestamp,
                    model: "anthropic.claude-fable-5-v1:0",
                    stopReason: "end_turn"
                ),
                event(
                    sessionID: "sonnet-session",
                    timestamp: latestTimestamp,
                    model: "claude-sonnet-5",
                    stopReason: "end_turn"
                )
            ]
        )

        let result = await ClaudeFableSessionScanner().scan(
            accounts: [account(id: accountAID, name: "Alpha")],
            projectDirectories: [accountAID: root],
            now: now
        )

        let session = try XCTUnwrap(result.sessions.first)
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(session.sourceSessionID, "fable-session")
        XCTAssertEqual(session.model, "claude-fable-5")
        XCTAssertEqual(session.firstObservedAt, firstTimestamp)
        XCTAssertEqual(session.lastObservedAt, latestTimestamp)
        XCTAssertEqual(session.state, .active)
    }

    func testDerivesActiveCompletedAndUnknownLifecycleStates() async throws {
        let root = try makeProjectsDirectory(named: "profile")
        try writeTranscript(
            to: root,
            name: "active.jsonl",
            events: [
                event(
                    sessionID: "active",
                    timestamp: now.addingTimeInterval(-60),
                    stopReason: "end_turn"
                )
            ]
        )
        try writeTranscript(
            to: root,
            name: "completed.jsonl",
            events: [
                event(
                    sessionID: "completed",
                    timestamp: now.addingTimeInterval(-3_600),
                    stopReason: "end_turn"
                )
            ]
        )
        try writeTranscript(
            to: root,
            name: "unknown.jsonl",
            events: [
                event(
                    sessionID: "unknown",
                    timestamp: now.addingTimeInterval(-3_600),
                    stopReason: nil
                )
            ],
            malformedTrailingLine: true
        )

        let result = await ClaudeFableSessionScanner().scan(
            accounts: [account(id: accountAID, name: "Alpha")],
            projectDirectories: [accountAID: root],
            now: now
        )
        let states = Dictionary(uniqueKeysWithValues: result.sessions.map { ($0.sourceSessionID, $0.state) })

        XCTAssertEqual(states["active"], .active)
        XCTAssertEqual(states["completed"], .completed)
        XCTAssertEqual(states["unknown"], .unknown)
        XCTAssertEqual(result.diagnostics[accountAID]?.malformedLineCount, 1)
    }

    func testUnavailableAndMalformedProfilesDoNotBlockReadableProfile() async throws {
        let readableRoot = try makeProjectsDirectory(named: "readable")
        let unavailableRoot = tempDirectory.appendingPathComponent("missing/projects", isDirectory: true)
        try writeTranscript(
            to: readableRoot,
            name: "readable.jsonl",
            events: [event(sessionID: "valid", timestamp: now)],
            malformedTrailingLine: true
        )

        let result = await ClaudeFableSessionScanner().scan(
            accounts: [account(id: accountAID, name: "Readable"), account(id: accountBID, name: "Missing")],
            projectDirectories: [accountAID: readableRoot, accountBID: unavailableRoot],
            now: now
        )

        XCTAssertEqual(result.sessions.map(\.sourceSessionID), ["valid"])
        XCTAssertEqual(result.diagnostics[accountAID]?.status, .scanned)
        XCTAssertEqual(result.diagnostics[accountAID]?.malformedLineCount, 1)
        XCTAssertEqual(result.diagnostics[accountBID]?.status, .unavailable)
    }

    func testUnchangedTranscriptUsesCacheUntilMetadataChanges() async throws {
        let root = try makeProjectsDirectory(named: "cached")
        let url = try writeTranscript(
            to: root,
            name: "cached.jsonl",
            events: [event(sessionID: "first1", timestamp: now)]
        )
        let scanner = ClaudeFableSessionScanner()
        let accounts = [account(id: accountAID, name: "Alpha")]
        let roots = [accountAID: root]

        let first = await scanner.scan(accounts: accounts, projectDirectories: roots, now: now)
        XCTAssertEqual(first.sessions.map(\.sourceSessionID), ["first1"])

        try overwriteTranscript(
            at: url,
            events: [event(sessionID: "second", timestamp: now)],
            modificationDate: now
        )
        let cached = await scanner.scan(accounts: accounts, projectDirectories: roots, now: now)
        XCTAssertEqual(cached.sessions.map(\.sourceSessionID), ["first1"])

        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(1)],
            ofItemAtPath: url.path
        )
        let refreshed = await scanner.scan(accounts: accounts, projectDirectories: roots, now: now)
        XCTAssertEqual(refreshed.sessions.map(\.sourceSessionID), ["second"])
    }

    func testStoreDeduplicatesAcrossRelaunchAndRetainsFirstObservation() throws {
        let store = ClaudeFableSessionStore(userDefaults: defaults)
        let first = session(
            id: "persisted",
            first: now.addingTimeInterval(-600),
            last: now.addingTimeInterval(-300),
            state: .active
        )
        store.merge([first], now: now)

        let relaunchedStore = ClaudeFableSessionStore(userDefaults: defaults)
        let repeated = ClaudeFableSession(
            sourceSessionID: "persisted",
            accountID: accountAID,
            accountName: "Renamed",
            model: "claude-fable-5",
            firstObservedAt: now.addingTimeInterval(-400),
            lastObservedAt: now.addingTimeInterval(-200),
            state: .active
        )
        let merged = relaunchedStore.merge([repeated], now: now)

        let persisted = try XCTUnwrap(merged.first)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(persisted.firstObservedAt, first.firstObservedAt)
        XCTAssertEqual(persisted.lastObservedAt, repeated.lastObservedAt)
        XCTAssertEqual(persisted.accountName, "Renamed")
    }

    func testStoreRepairsDuplicatePersistedIdentifiersWithoutTrapping() throws {
        let first = session(
            id: "duplicate",
            first: now.addingTimeInterval(-600),
            last: now.addingTimeInterval(-500),
            state: .unknown
        )
        let newer = ClaudeFableSession(
            sourceSessionID: "duplicate",
            accountID: accountAID,
            accountName: "Renamed",
            model: "claude-fable-5",
            firstObservedAt: now.addingTimeInterval(-400),
            lastObservedAt: now.addingTimeInterval(-300),
            state: .completed
        )
        defaults.set(
            try JSONEncoder().encode([first, newer]),
            forKey: StorageKeys.claudeFableSessions
        )

        let loaded = ClaudeFableSessionStore(userDefaults: defaults).load(now: now)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.firstObservedAt, first.firstObservedAt)
        XCTAssertEqual(loaded.first?.lastObservedAt, newer.lastObservedAt)
        XCTAssertEqual(loaded.first?.accountName, "Renamed")
        XCTAssertEqual(loaded.first?.state, .completed)
    }

    func testStorePrunesExpiredHistoryAndAgesStaleActiveRecords() throws {
        let store = ClaudeFableSessionStore(userDefaults: defaults)
        let expired = session(
            id: "expired",
            first: now.addingTimeInterval(-31 * 24 * 3_600),
            last: now.addingTimeInterval(-31 * 24 * 3_600),
            state: .completed
        )
        let staleActive = session(
            id: "stale-active",
            first: now.addingTimeInterval(-3_600),
            last: now.addingTimeInterval(-3_600),
            state: .active
        )

        let retained = store.merge([expired, staleActive], now: now)

        XCTAssertEqual(retained.map(\.sourceSessionID), ["stale-active"])
        XCTAssertEqual(retained.first?.state, .unknown)
    }

    func testPersistedMetadataExcludesTranscriptContentAndEnvironmentFields() async throws {
        let root = try makeProjectsDirectory(named: "private")
        try writeTranscript(
            to: root,
            name: "private.jsonl",
            events: [
                event(
                    sessionID: "private-session",
                    timestamp: now,
                    promptContent: "TOP_SECRET_PROMPT",
                    cwd: "/private/customer/repository"
                )
            ]
        )
        let result = await ClaudeFableSessionScanner().scan(
            accounts: [account(id: accountAID, name: "Alpha")],
            projectDirectories: [accountAID: root],
            now: now
        )
        ClaudeFableSessionStore(userDefaults: defaults).merge(result.sessions, now: now)

        let data = try XCTUnwrap(defaults.data(forKey: StorageKeys.claudeFableSessions))
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains("TOP_SECRET_PROMPT"))
        XCTAssertFalse(encoded.contains("/private/customer/repository"))
        XCTAssertFalse(encoded.contains("\"content\""))
        XCTAssertFalse(encoded.contains("\"cwd\""))
    }

    func testProjectsDirectoryResolvesDefaultAndExplicitProfiles() {
        let defaultAccount = ClaudeCodeAccount(
            id: ClaudeCodeAccount.defaultID,
            name: "Default",
            configDirectory: nil
        )
        let explicitAccount = account(id: accountAID, name: "Explicit", configDirectory: "~/profile-a")

        XCTAssertEqual(
            ClaudeFableSessionScanner.projectsDirectory(
                for: defaultAccount,
                environment: [:],
                realHomeDirectory: "/Users/tester"
            ).path,
            "/Users/tester/.claude/projects"
        )
        XCTAssertEqual(
            ClaudeFableSessionScanner.projectsDirectory(
                for: explicitAccount,
                environment: [:],
                realHomeDirectory: "/Users/tester"
            ).path,
            "/Users/tester/profile-a/projects"
        )
    }

    private func account(
        id: UUID,
        name: String,
        configDirectory: String? = nil
    ) -> ClaudeCodeAccount {
        ClaudeCodeAccount(id: id, name: name, configDirectory: configDirectory)
    }

    private func session(
        id: String,
        first: Date,
        last: Date,
        state: ClaudeFableSession.State
    ) -> ClaudeFableSession {
        ClaudeFableSession(
            sourceSessionID: id,
            accountID: accountAID,
            accountName: "Alpha",
            model: "claude-fable-5",
            firstObservedAt: first,
            lastObservedAt: last,
            state: state
        )
    }

    private func makeProjectsDirectory(named name: String) throws -> URL {
        let directory = tempDirectory
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func writeTranscript(
        to directory: URL,
        name: String,
        events: [[String: Any]],
        malformedTrailingLine: Bool = false
    ) throws -> URL {
        var lines = try events.map { event -> String in
            let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        }
        if malformedTrailingLine {
            lines.append("{partially-written")
        }

        let url = directory.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: url.path
        )
        return url
    }

    private func overwriteTranscript(
        at url: URL,
        events: [[String: Any]],
        modificationDate: Date
    ) throws {
        let lines = try events.map { event -> String in
            let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: url.path
        )
    }

    private func event(
        sessionID: String,
        timestamp: Date,
        model: String = "claude-fable-5",
        stopReason: String? = "end_turn",
        promptContent: String = "safe fixture",
        cwd: String = "/tmp/fixture"
    ) -> [String: Any] {
        [
            "type": "assistant",
            "sessionId": sessionID,
            "timestamp": FlexibleISO8601.fractional.string(from: timestamp),
            "cwd": cwd,
            "message": [
                "model": model,
                "stop_reason": stopReason.map { $0 as Any } ?? NSNull(),
                "content": promptContent,
                "usage": [
                    "input_tokens": 10,
                    "output_tokens": 5
                ]
            ]
        ]
    }
}
