import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Account-endpoint client. Fixtures are synthetic and contain placeholder
/// secrets so a log, error, or cached metric that copies them fails the test.
final class MuseCodeServiceTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testRequestUsesTheAccountEndpointAndDropsSecrets() async throws {
        let harness = ServiceHarness(now: origin)
        let metrics = try await harness.service.fetchUsageMetrics()

        let request = try XCTUnwrap(harness.requests.first)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "api.meta.ai")
        XCTAssertEqual(request.url?.path, "/muse-code/key")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, Data("{}".utf8))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(ServiceHarness.token)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-version"), "1.0.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(metrics.sessionLimit?.used, 22)
        XCTAssertEqual(metrics.sessionLimit?.windowSeconds, 300 * 60)
        XCTAssertEqual(metrics.weeklyLimit?.used, 44)
        XCTAssertEqual(harness.service.planName, "Muse Code High Usage")
        XCTAssertNil(harness.service.statusNote)
        XCTAssertNil(harness.service.asOfNote)
        XCTAssertNil(harness.service.lastError)
        assertNoSecrets(in: [encoded(metrics), harness.service.planName])
    }

    func testRateLimitCooldownSkipsTheNextSendAndTheKeychain() async throws {
        let harness = ServiceHarness(now: origin, inlineToken: false)
        _ = try await harness.service.fetchUsageMetrics()
        harness.now = origin.addingTimeInterval(61)
        harness.enqueue(harness.http(429, retryAfter: "120"))

        do {
            _ = try await harness.service.fetchUsageMetrics()
            XCTFail("expected HTTP 429")
        } catch {
            assertAPIError(error, "HTTP 429")
            assertNoSecrets(in: [error.localizedDescription, String(describing: error)])
        }

        let readsAfterLimit = harness.keychainReads
        harness.now = origin.addingTimeInterval(122)
        do {
            _ = try await harness.service.fetchUsageMetrics()
            XCTFail("cooldown should still be active")
        } catch {
            assertAPIError(error, "HTTP 429")
        }
        XCTAssertEqual(harness.requests.count, 2)
        XCTAssertEqual(harness.keychainReads, readsAfterLimit)
    }

    func testUnauthorizedClearsBarsAndALaterIdleDoesNotRestoreThem() async throws {
        for status in [401, 403] {
            let harness = ServiceHarness(now: origin)
            let first = try await harness.service.fetchUsageMetrics()
            XCTAssertEqual(first.sessionLimit?.used, 22)
            harness.now = origin.addingTimeInterval(61)
            harness.enqueue(harness.http(status))

            let rejected = try await harness.service.fetchUsageMetrics()
            XCTAssertFalse(rejected.hasData)
            XCTAssertEqual(harness.requests.count, 2)
            XCTAssertEqual(harness.service.statusNote, MuseCodeCopy.reconnect)
            XCTAssertNil(harness.service.asOfNote)
            guard case .notAuthenticated = harness.service.lastError else {
                return XCTFail("expected notAuthenticated for \(status)")
            }
            assertNoSecrets(in: [
                harness.service.statusNote,
                harness.service.lastError?.localizedDescription,
                encoded(rejected)
            ])

            harness.now = origin.addingTimeInterval(90)
            let replayed = try await harness.service.fetchUsageMetrics()
            XCTAssertFalse(replayed.hasData)
            XCTAssertEqual(harness.requests.count, 2)
            guard case .notAuthenticated = harness.service.lastError else {
                return XCTFail("replay should keep notAuthenticated for \(status)")
            }

            harness.now = origin.addingTimeInterval(122)
            harness.enqueue(harness.idle())
            let idle = try await harness.service.fetchUsageMetrics()
            XCTAssertFalse(idle.hasData)
            XCTAssertEqual(harness.service.statusNote, MuseCodeCopy.idle)
            XCTAssertNil(harness.service.asOfNote)
            XCTAssertNil(harness.service.lastError)
            assertNoSecrets(in: [encoded(idle), harness.service.statusNote])
        }
    }

    func testServerErrorKeepsLastGoodUntilBothResetsPass() async throws {
        let harness = ServiceHarness(now: origin)
        let reset = origin.addingTimeInterval(10_000)
        harness.enqueue(harness.quota(sessionReset: reset, weeklyReset: reset))
        let first = try await harness.service.fetchUsageMetrics()

        harness.now = origin.addingTimeInterval(61)
        harness.enqueue(harness.http(503))
        do {
            _ = try await harness.service.fetchUsageMetrics()
            XCTFail("expected HTTP 503")
        } catch {
            assertAPIError(error, "HTTP 503")
            assertNoSecrets(in: [error.localizedDescription])
        }

        harness.now = origin.addingTimeInterval(122)
        harness.enqueue(harness.idle())
        let kept = try await harness.service.fetchUsageMetrics()
        XCTAssertEqual(kept.sessionLimit?.used, 22)
        XCTAssertEqual(kept.weeklyLimit?.used, 44)
        XCTAssertEqual(kept.lastUpdated, first.lastUpdated)
        XCTAssertEqual(harness.service.statusNote, MuseCodeCopy.asOf(iso(first.lastUpdated)))
        XCTAssertEqual(harness.service.asOfNote, MuseCodeCopy.asOf(iso(first.lastUpdated)))
        assertNoSecrets(in: [harness.service.asOfNote, encoded(kept)])

        harness.now = reset
        harness.enqueue(harness.idle())
        let gone = try await harness.service.fetchUsageMetrics()
        XCTAssertFalse(gone.hasData)
        XCTAssertEqual(harness.service.statusNote, MuseCodeCopy.idle)
        XCTAssertNil(harness.service.asOfNote)
    }

    func testMinimumIntervalSkipsASecondSend() async throws {
        let harness = ServiceHarness(now: origin)
        _ = try await harness.service.fetchUsageMetrics()
        harness.now = origin.addingTimeInterval(59)
        _ = try await harness.service.fetchUsageMetrics()
        XCTAssertEqual(harness.requests.count, 1)
        harness.now = origin.addingTimeInterval(60)
        _ = try await harness.service.fetchUsageMetrics()
        XCTAssertEqual(harness.requests.count, 2)
    }

    func testOverlappingFetchesShareOneRequest() async throws {
        let harness = ServiceHarness(now: origin)
        harness.suspend = true
        let first = Task { try await harness.service.fetchUsageMetrics() }
        try await waitUntil { harness.requests.count == 1 }
        let second = Task { try await harness.service.fetchUsageMetrics() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(harness.requests.count, 1)
        harness.gate.release()
        let left = try await first.value
        let right = try await second.value
        XCTAssertEqual(left.sessionLimit?.used, right.sessionLimit?.used)
        XCTAssertEqual(harness.requests.count, 1)
    }

    func testDisabledProviderPerformsNoIO() async throws {
        let harness = ServiceHarness(now: origin)
        harness.enabled = false
        XCTAssertFalse(harness.service.hasAccess)
        let metrics = try await harness.service.fetchUsageMetrics()
        XCTAssertFalse(metrics.hasData)
        XCTAssertNil(harness.service.lastError)
        XCTAssertNil(harness.service.statusNote)
        XCTAssertEqual(harness.fileExistsCalls, 0)
        XCTAssertEqual(harness.authLoads, 0)
        XCTAssertEqual(harness.keychainReads, 0)
        XCTAssertTrue(harness.requests.isEmpty)
    }

    func testPaymentRequiredThenInactiveKeepThePlanVerbatim() async throws {
        let harness = ServiceHarness(now: origin)
        harness.enqueue(harness.payment(plan: "plan-as-given"))
        let payment = try await harness.service.fetchUsageMetrics()
        XCTAssertFalse(payment.hasData)
        XCTAssertEqual(harness.service.planName, "plan-as-given")
        XCTAssertEqual(harness.service.statusNote, MuseCodeCopy.paymentRequired)
        XCTAssertNil(harness.service.lastError)

        harness.now = origin.addingTimeInterval(61)
        harness.enqueue(harness.inactive(plan: "plan-as-given"))
        let inactive = try await harness.service.fetchUsageMetrics()
        XCTAssertFalse(inactive.hasData)
        XCTAssertEqual(harness.service.planName, "plan-as-given")
        XCTAssertEqual(harness.service.statusNote, MuseCodeCopy.noSubscription)
        XCTAssertNil(harness.service.lastError)
    }

    func testConnectUsesInteractiveKeychainAndStillHonorsCooldown() async throws {
        let harness = ServiceHarness(now: origin, inlineToken: false)
        _ = try await harness.service.fetchUsageMetrics()
        _ = try await harness.service.connect()
        XCTAssertEqual(harness.requests.count, 2)
        XCTAssertEqual(harness.keychainModes, [.background, .interactive])

        harness.now = origin.addingTimeInterval(61)
        harness.enqueue(harness.http(429, retryAfter: "120"))
        do {
            _ = try await harness.service.connect()
            XCTFail("expected HTTP 429")
        } catch {
            assertAPIError(error, "HTTP 429")
            assertNoSecrets(in: [error.localizedDescription, String(describing: error)])
        }
        let reads = harness.keychainReads
        do {
            _ = try await harness.service.connect()
            XCTFail("cooldown should skip the next connect")
        } catch {
            assertAPIError(error, "HTTP 429")
        }
        XCTAssertEqual(harness.requests.count, 3)
        XCTAssertEqual(harness.keychainReads, reads)
    }

    func testConnectDuringASilentReadReusesThatResult() async throws {
        let harness = ServiceHarness(now: origin, inlineToken: false)
        harness.suspend = true
        let silent = Task { try await harness.service.fetchUsageMetrics() }
        try await waitUntil { harness.requests.count == 1 }
        let connect = Task { try await harness.service.connect() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(harness.requests.count, 1)
        XCTAssertEqual(harness.keychainModes, [.background])
        harness.gate.release()
        _ = try await silent.value
        let connected = try await connect.value
        XCTAssertEqual(connected.sessionLimit?.used, 22)
        XCTAssertEqual(harness.requests.count, 1)
        XCTAssertEqual(harness.keychainModes, [.background])
    }

    func testConnectPromptsAfterBackgroundKeychainRefusal() async throws {
        let harness = ServiceHarness(now: origin, inlineToken: false)
        harness.blockBackground = true
        let silent = try await harness.service.fetchUsageMetrics()
        XCTAssertFalse(silent.hasData)
        XCTAssertEqual(harness.service.statusNote, MuseCodeCopy.needsKeychainAccess)
        XCTAssertNil(harness.service.lastError)
        XCTAssertTrue(harness.requests.isEmpty)

        let connected = try await harness.service.connect()
        XCTAssertEqual(connected.sessionLimit?.used, 22)
        XCTAssertEqual(harness.keychainModes, [.background, .interactive])
        XCTAssertEqual(harness.requests.count, 1)
    }

    func testSignInAnswersAreEmptyAndClearALaterIdle() async throws {
        let harness = ServiceHarness(now: origin)
        let first = try await harness.service.fetchUsageMetrics()
        XCTAssertEqual(first.sessionLimit?.used, 22)

        harness.now = origin.addingTimeInterval(61)
        harness.authOverride = .missing
        let signedOut = try await harness.service.fetchUsageMetrics()
        XCTAssertFalse(signedOut.hasData)
        XCTAssertEqual(harness.service.statusNote, MuseCodeCopy.notSignedIn)
        XCTAssertNil(harness.service.lastError)
        XCTAssertEqual(harness.requests.count, 1)

        harness.now = origin.addingTimeInterval(62)
        harness.authOverride = .data(Data(
            #"{"providers":{"meta":{"mechanism":"oauth","access_token":"not-dca"}}}"#.utf8
        ))
        let rejected = try await harness.service.fetchUsageMetrics()
        XCTAssertFalse(rejected.hasData)
        XCTAssertEqual(harness.service.statusNote, MuseCodeCopy.rejectedToken)
        XCTAssertNil(harness.service.lastError)

        harness.now = origin.addingTimeInterval(63)
        harness.authOverride = .unreadable
        let unreadable = try await harness.service.fetchUsageMetrics()
        XCTAssertFalse(unreadable.hasData)
        XCTAssertEqual(harness.service.statusNote, MuseCodeCopy.unreadable)
        XCTAssertNil(harness.service.lastError)
        XCTAssertEqual(harness.requests.count, 1)

        harness.now = origin.addingTimeInterval(122)
        harness.authOverride = nil
        harness.enqueue(harness.idle())
        let idle = try await harness.service.fetchUsageMetrics()
        XCTAssertFalse(idle.hasData)
        XCTAssertEqual(harness.service.statusNote, MuseCodeCopy.idle)
        XCTAssertNil(harness.service.asOfNote)
        XCTAssertNil(harness.service.lastError)
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func encoded(_ metrics: UsageMetrics) -> String {
        let data = (try? JSONEncoder().encode(metrics)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func assertAPIError(
        _ error: Error,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .apiError(actual) = error as? ServiceError else {
            return XCTFail("expected apiError, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(actual, message, file: file, line: line)
    }

    private func assertNoSecrets(
        in values: [String?],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let blob = values.compactMap { $0 }.joined(separator: "\n")
        for secret in [ServiceHarness.email, ServiceHarness.inferenceKey, ServiceHarness.token, ServiceHarness.marker] {
            XCTAssertFalse(blob.contains(secret), "credential material leaked", file: file, line: line)
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for the request")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private nonisolated final class ServiceHarness: @unchecked Sendable {
    static let token = "dca:service-token"
    static let email = "person@example.invalid"
    static let inferenceKey = "mk-inference-secret-value"
    static let marker = "raw-body-marker"

    let service: MuseCodeService
    let gate = MuseCodeSuspendGate()
    var suspend = false
    var blockBackground = false
    var authOverride: MuseCodeAuthLoad?

    private let lock = NSLock()
    private var instant: Date
    private var isEnabled = true
    private var usesInlineToken: Bool
    private var storedRequests: [URLRequest] = []
    private var queued: [MuseCodeHTTPResponse] = []
    private var modes: [ClaudeKeychainAccessMode] = []
    private var reads = 0
    private var loads = 0
    private var exists = 0

    init(now: Date, inlineToken: Bool = true) {
        instant = now
        usesInlineToken = inlineToken
        let box = Box()
        service = MuseCodeService(dependencies: box.dependencies)
        box.harness = self
    }

    var now: Date {
        get { locked { instant } }
        set { locked { instant = newValue } }
    }

    var enabled: Bool {
        get { locked { isEnabled } }
        set { locked { isEnabled = newValue } }
    }

    var requests: [URLRequest] { locked { storedRequests } }
    var keychainModes: [ClaudeKeychainAccessMode] { locked { modes } }
    var keychainReads: Int { locked { reads } }
    var authLoads: Int { locked { loads } }
    var fileExistsCalls: Int { locked { exists } }

    func enqueue(_ response: MuseCodeHTTPResponse) {
        locked { queued.append(response) }
    }

    func quota(
        sessionReset: Date = Date(timeIntervalSince1970: 1_800_018_000),
        weeklyReset: Date = Date(timeIntervalSince1970: 1_900_000_000)
    ) -> MuseCodeHTTPResponse {
        let session = Int(sessionReset.timeIntervalSince1970)
        let weekly = Int(weeklyReset.timeIntervalSince1970)
        let json = """
        {"\(Self.marker)":true,"api_key":"\(Self.inferenceKey)","user_email":"\(Self.email)",\
        "is_subs_active":true,"require_payment":false,"subs_tier_name":"Muse Code High Usage",\
        "subs_usage":{"window":{"used_percent":22,"window_duration_mins":300,"resets_at":\(session)},\
        "weekly":{"used_percent":44,"resets_at":\(weekly)}}}
        """
        return MuseCodeHTTPResponse(status: 200, retryAfter: nil, body: Data(json.utf8))
    }

    func idle() -> MuseCodeHTTPResponse {
        http(200, body: #"{"is_subs_active":true,"require_payment":false,"subs_tier_name":"Muse Code High Usage"}"#)
    }

    func payment(plan: String) -> MuseCodeHTTPResponse {
        http(200, body: """
        {"is_subs_active":true,"require_payment":true,"subs_tier_name":"\(plan)",\
        "subs_usage":{"window":{"used_percent":10}}}
        """)
    }

    func inactive(plan: String) -> MuseCodeHTTPResponse {
        http(200, body: """
        {"is_subs_active":false,"require_payment":false,"subs_tier_name":"\(plan)",\
        "subs_usage":{"window":{"used_percent":10}}}
        """)
    }

    func http(_ status: Int, retryAfter: String? = nil, body: String? = nil) -> MuseCodeHTTPResponse {
        let payload = body ?? """
        {"\(Self.marker)":true,"api_key":"\(Self.inferenceKey)","user_email":"\(Self.email)"}
        """
        return MuseCodeHTTPResponse(status: status, retryAfter: retryAfter, body: Data(payload.utf8))
    }

    fileprivate func noteExists() -> Bool {
        locked {
            exists += 1
            return true
        }
    }

    fileprivate func noteAuth() -> MuseCodeAuthLoad {
        locked { loads += 1 }
        if let authOverride { return authOverride }
        return .data(authFile())
    }

    fileprivate func noteKeychain(_ mode: ClaudeKeychainAccessMode) -> ClaudeKeychainReadOutcome<Data> {
        locked {
            reads += 1
            modes.append(mode)
        }
        if blockBackground, mode == .background {
            return .interactionRequired
        }
        let secret = #"{"access_token":"\#(Self.token)","api_key":"\#(Self.inferenceKey)"}"#
        return .value(Data(secret.utf8))
    }

    fileprivate func respond(_ request: URLRequest) async -> MuseCodeHTTPResponse {
        locked { storedRequests.append(request) }
        if suspend {
            await gate.wait()
        }
        return locked { queued.isEmpty ? quota() : queued.removeFirst() }
    }

    private func authFile() -> Data {
        let inline = usesInlineToken ? #""access_token":"\#(Self.token)","# : ""
        let json = """
        {"email":"\(Self.email)","providers":{"meta":{\(inline)"mechanism":"oauth","subs_active":true}}}
        """
        return Data(json.utf8)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Breaks the init cycle: dependencies close over the harness, and the
    /// service has to exist before those closures run.
    private nonisolated final class Box: @unchecked Sendable {
        weak var harness: ServiceHarness?
        var dependencies: MuseCodeServiceDependencies {
            MuseCodeServiceDependencies(
                isEnabled: { self.harness?.enabled ?? false },
                environment: ["MUSE_AUTH_PATH": "/tmp/muse-auth.json"],
                realHomeDirectory: "/Users/tester",
                now: { self.harness?.now ?? Date() },
                minimumInterval: 60,
                gate: ClaudeUsageRateLimitGate(),
                fileExists: { _ in self.harness?.noteExists() ?? false },
                loadAuth: { _ in self.harness?.noteAuth() ?? .missing },
                keychain: { self.harness?.noteKeychain($0) ?? .notFound },
                transport: { request in
                    guard let harness = self.harness else {
                        return MuseCodeHTTPResponse(status: 500, retryAfter: nil, body: Data())
                    }
                    return await harness.respond(request)
                }
            )
        }
    }
}

private nonisolated final class MuseCodeSuspendGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    /// A release that arrives before `wait` must not drop the continuation.
    private var open = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if open {
                open = false
                lock.unlock()
                continuation.resume()
                return
            }
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        let pending = continuations
        continuations.removeAll()
        if pending.isEmpty {
            open = true
        }
        lock.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }
}
