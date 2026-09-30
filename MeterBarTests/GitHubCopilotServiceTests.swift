import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// The tested support matrix for `GitHubCopilotService`: which account shapes
/// yield a quota, which are usage-only, and which are unsupported.
final class GitHubCopilotServiceTests: XCTestCase {

    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        settingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubCopilotServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: settingsDirectory)
        try super.tearDownWithError()
    }

    // MARK: - Personal accounts

    func testUsageOnlyQuantityFormattingAcceptsLargeFiniteAndFractionalValues() async throws {
        for quantity in ["1e100", "1.5"] {
            let data = Data(#"{"usageItems":[{"unitType":"credits","grossQuantity":\#(quantity)}]}"#.utf8)
            let (service, _, _) = makeService(respond: Self.route([Self.creditsPath: .success(data)]))
            let metrics = try await service.fetchUsageMetrics()
            XCTAssertFalse(metrics.hasData)
            XCTAssertNil(service.latestUsageObservation)
            let note = try XCTUnwrap(service.supportNote)
            let reported = try XCTUnwrap(note.components(separatedBy: "This month: ").last)
                .components(separatedBy: " AI credits")[0]
            XCTAssertEqual(Double(reported), quantity == "1.5" ? 2 : 1e100)
        }
    }

    func testPersonalAICreditsAreUsageOnlyWithNoInventedAllowance() async throws {
        let (service, _, _) = makeService(respond: Self.route([Self.creditsPath: .success(Self.creditUsage)]))

        let metrics = try await service.fetchUsageMetrics()

        XCTAssertFalse(metrics.hasData, "no documented allowance means no quota bar")
        XCTAssertEqual(service.support, .usageOnly(.noDocumentedAllowance))
        let note = try XCTUnwrap(service.supportNote)
        XCTAssertTrue(note.contains("150 AI credits"), note)
        XCTAssertTrue(note.contains("no allowance"), note)
        XCTAssertNil(service.latestUsageObservation)
    }

    func testLegacyPremiumRequestsAreUsageOnlyBecauseTheEntitlementIsUndocumented() async throws {
        let (service, _, _) = makeService(respond: Self.route([
            Self.creditsPath: .success(Self.emptyUsage),
            Self.premiumPath: .success(Self.premiumUsage),
        ]))

        _ = try await service.fetchUsageMetrics()

        XCTAssertEqual(service.support, .usageOnly(.legacyEntitlementUndocumented))
        XCTAssertTrue(service.supportNote?.contains("40 premium requests") ?? false)
    }

    func testLegacyIsReachedWhenTheCreditReportIsNotFoundToo() async throws {
        let (service, _, _) = makeService(respond: Self.route([
            Self.creditsPath: .failure(.apiError("HTTP 404")),
            Self.premiumPath: .success(Self.premiumUsage),
        ]))

        _ = try await service.fetchUsageMetrics()

        XCTAssertEqual(service.support, .usageOnly(.legacyEntitlementUndocumented))
    }

    func testEmptyPersonalReportsPointAtOrganizationManagement() async throws {
        let (service, _, _) = makeService(respond: Self.route([
            Self.creditsPath: .success(Self.emptyUsage),
            Self.premiumPath: .success(Self.emptyUsage),
        ]))

        _ = try await service.fetchUsageMetrics()

        XCTAssertEqual(service.support, .usageOnly(.noPersonalUsage))
    }

    func testPersonal403And404AreUnsupportedAccountsNotFailures() async throws {
        for (status, expected) in [
            ("HTTP 403", GitHubCopilotAccountSupport.unsupported(.missingPermission)),
            ("HTTP 404", GitHubCopilotAccountSupport.unsupported(.notAvailable)),
        ] {
            let (service, _, _) = makeService(respond: { _ in throw ServiceError.apiError(status) })

            let metrics = try await service.fetchUsageMetrics()

            XCTAssertFalse(metrics.hasData)
            XCTAssertEqual(service.support, expected, status)
            XCTAssertNil(service.lastError, "an unsupported account is an answer, not a refresh failure")
        }
    }

    // MARK: - Organization-managed accounts

    func testOrganizationUserBudgetIsTheOnlyQuota() async throws {
        let (service, recorder, _) = makeService(
            config: organization,
            respond: Self.route([Self.budgetsPath: .success(Self.budgetPage)])
        )

        let metrics = try await service.fetchUsageMetrics()

        let limit = try XCTUnwrap(metrics.weeklyLimit)
        XCTAssertNil(metrics.sessionLimit)
        XCTAssertEqual(limit.used, 9.5)
        XCTAssertEqual(limit.total, 25)
        XCTAssertEqual(limit.periodKind, .monthly)
        // 2026-10-01 00:00 UTC, the start of the next billing month.
        XCTAssertEqual(limit.resetTime, Date(timeIntervalSince1970: 1_790_812_800))
        XCTAssertEqual(limit.windowSeconds, 30 * 86400)
        XCTAssertEqual(service.support, .quota)
        XCTAssertNil(service.supportNote)

        let observation = try XCTUnwrap(service.latestUsageObservation)
        XCTAssertEqual(observation.unit, .usd)
        XCTAssertEqual(observation.runningTotal, 9.5)
        XCTAssertEqual(observation.dayBoundary, .utc)

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.path, Self.budgetsPath)
        let query = URLComponents(url: request.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?
            .queryItems?.reduce(into: [String: String]()) { $0[$1.name] = $1.value } ?? [:]
        XCTAssertEqual(query["user"], "octocat")
        XCTAssertEqual(query["per_page"], "100")
    }

    func testOrganizationWithoutAUserBudgetHasNoCap() async throws {
        let none = Data(#"{"budgets":[],"user":"octocat","has_next_page":false,"total_count":0}"#.utf8)
        let (service, _, _) = makeService(config: organization, respond: Self.route([Self.budgetsPath: .success(none)]))

        let metrics = try await service.fetchUsageMetrics()

        XCTAssertFalse(metrics.hasData)
        XCTAssertEqual(service.support, .usageOnly(.noUserBudget))
    }

    func testOrganizationBudgetOnAnotherProductIsRejected() async throws {
        let actions = Data(#"""
        {"budgets":[{"id":"b1","budget_product_sku":"actions_linux","budget_scope":"organization","budget_amount":500}],
         "effective_budget":{"id":"b1","budget_amount":500,"consumed_amount":10},"has_next_page":false}
        """#.utf8)
        let (service, _, _) = makeService(
            config: organization,
            respond: Self.route([Self.budgetsPath: .success(actions)])
        )

        let metrics = try await service.fetchUsageMetrics()

        XCTAssertFalse(metrics.hasData)
        XCTAssertEqual(service.support, .unsupported(.budgetNotForCopilot))
    }

    func testOrganization403And404AreUnsupported() async throws {
        for (status, expected) in [
            ("HTTP 403", GitHubCopilotAccountSupport.unsupported(.missingPermission)),
            ("HTTP 404", GitHubCopilotAccountSupport.unsupported(.notAvailable)),
        ] {
            let (service, _, _) = makeService(
                config: organization,
                respond: { _ in throw ServiceError.apiError(status) }
            )

            _ = try await service.fetchUsageMetrics()

            XCTAssertEqual(service.support, expected, status)
        }
    }

    func testBudgetPaginationFollowsHasNextPageAndAggregatesAcrossPages() async throws {
        let page1 = Data(#"""
        {"budgets":[{"id":"b1","budget_product_sku":"ai_credits","budget_scope":"user","budget_amount":40}],
         "has_next_page":true,"total_count":2}
        """#.utf8)
        let page2 = Data(#"""
        {"budgets":[{"id":"b2","budget_product_sku":"actions","budget_scope":"organization","budget_amount":9}],
         "effective_budget":{"id":"b1","budget_amount":40,"consumed_amount":4},"has_next_page":false,"total_count":2}
        """#.utf8)
        let (service, recorder, _) = makeService(config: organization, respond: { request in
            let page = URLComponents(url: request.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "page" }?.value
            return page == "1" ? page1 : page2
        })

        let metrics = try await service.fetchUsageMetrics()

        XCTAssertEqual(metrics.weeklyLimit?.used, 4)
        XCTAssertEqual(metrics.weeklyLimit?.total, 40)
        XCTAssertEqual(recorder.requests.count, 2)
    }

    func testPaginationIsBoundedEvenIfGitHubNeverStopsPaging() async throws {
        let forever = Data(#"{"budgets":[],"has_next_page":true}"#.utf8)
        let (service, recorder, _) = makeService(config: organization, respond: { _ in forever })

        _ = try await service.fetchUsageMetrics()

        XCTAssertEqual(recorder.requests.count, GitHubCopilotService.maximumBudgetPages)
    }

    // MARK: - Requests

    func testRequestsGoOnlyToTheDocumentedEndpointsWithTheVersionHeader() async throws {
        let (service, recorder, _) = makeService(respond: Self.route([Self.creditsPath: .success(Self.creditUsage)]))

        _ = try await service.fetchUsageMetrics()

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "api.github.com")
        XCTAssertEqual(request.url?.path, Self.creditsPath)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer github_pat_secret_value")
        let headerNames = Set((request.allHTTPHeaderFields ?? [:]).keys)
        XCTAssertEqual(headerNames, ["Accept", "Authorization", "X-GitHub-Api-Version", "User-Agent"])
        XCTAssertNil(request.httpBody)
        for recorded in recorder.requests {
            XCTAssertEqual(recorded.url?.host, "api.github.com")
        }
    }

    func testBillingMonthIsTheUTCCalendarMonth() {
        let month = GitHubCopilotService.billingMonth(containing: now)

        XCTAssertEqual(month.year, 2026)
        XCTAssertEqual(month.month, 9)
        XCTAssertEqual(month.start, Date(timeIntervalSince1970: 1_790_812_800 - 30 * 86400))
        XCTAssertEqual(month.nextStart, Date(timeIntervalSince1970: 1_790_812_800))
    }

    // MARK: - Credentials and configuration

    func testBadTokenClearsAccessUntilReplaced() async throws {
        let (service, _, _) = makeService(respond: { _ in throw ServiceError.notAuthenticated })
        XCTAssertTrue(service.hasAccess)

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected notAuthenticated")
        } catch ServiceError.notAuthenticated {
            XCTAssertFalse(service.hasAccess)
        }

        XCTAssertTrue(service.saveToken("github_pat_replacement"))
        XCTAssertTrue(service.hasAccess)
    }

    func testAccessNeedsATokenAndACompleteAccount() {
        let (noUser, _, _) = makeService(config: GitHubCopilotAccountConfig(), respond: { _ in Data() })
        XCTAssertFalse(noUser.hasAccess)

        let (orgWithoutOrg, _, _) = makeService(
            config: GitHubCopilotAccountConfig(scope: .organization, username: "octocat"),
            respond: { _ in Data() }
        )
        XCTAssertFalse(orgWithoutOrg.hasAccess)

        let (noToken, _, _) = makeService(token: nil, respond: { _ in Data() })
        XCTAssertFalse(noToken.hasAccess)

        let (ready, _, _) = makeService(respond: { _ in Data() })
        XCTAssertTrue(ready.hasAccess)
    }

    func testNoTokenIsNotAuthenticatedWithoutNetwork() async {
        let (service, recorder, _) = makeService(token: nil, respond: { _ in Data() })

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected notAuthenticated")
        } catch ServiceError.notAuthenticated {
            let sent = recorder.requests
            XCTAssertTrue(sent.isEmpty)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testInvalidLoginsCanNeverBeSavedOrReachAPath() {
        let (service, _, _) = makeService(respond: { _ in Data() })

        service.saveConfiguration(GitHubCopilotAccountConfig(
            scope: .organization,
            username: "octo/../admin",
            organization: "acme?x=1"
        ))

        XCTAssertNil(service.configuration.username)
        XCTAssertNil(service.configuration.organization)
        let reloaded = GitHubCopilotAccountConfig.load(directory: settingsDirectory)
        XCTAssertNil(reloaded.username)
        XCTAssertNil(reloaded.organization)
    }

    func testConfigurationRoundTripsAndDropsTheClassificationWhenItChanges() async throws {
        let (service, _, _) = makeService(respond: Self.route([Self.creditsPath: .success(Self.creditUsage)]))
        _ = try await service.fetchUsageMetrics()
        XCTAssertEqual(
            GitHubCopilotAccountConfig.loadSupport(directory: settingsDirectory),
            .usageOnly(.noDocumentedAllowance)
        )

        service.saveConfiguration(GitHubCopilotAccountConfig(
            scope: .organization,
            username: "octocat",
            organization: "acme"
        ))

        XCTAssertNil(service.support)
        XCTAssertNil(service.supportNote)
        XCTAssertNil(GitHubCopilotAccountConfig.loadSupport(directory: settingsDirectory))
        XCTAssertEqual(
            GitHubCopilotAccountConfig.load(directory: settingsDirectory),
            GitHubCopilotAccountConfig(scope: .organization, username: "octocat", organization: "acme")
        )
    }

    // MARK: - Redaction

    func testNeitherTheTokenNorRawBillingPayloadsAreStoredOrSurfaced() async throws {
        let (service, _, _) = makeService(respond: Self.route([Self.creditsPath: .success(Self.creditUsage)]))
        let metrics = try await service.fetchUsageMetrics()

        let encoded = try String(data: JSONEncoder().encode(metrics), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("github_pat_secret_value"))
        XCTAssertFalse(encoded.contains("Copilot AI Credits"))

        let files = try FileManager.default.contentsOfDirectory(atPath: settingsDirectory.path)
        let stored = try files
            .map { try String(contentsOf: settingsDirectory.appendingPathComponent($0), encoding: .utf8) }
            .joined()
        XCTAssertFalse(stored.contains("github_pat_secret_value"))
        XCTAssertFalse(stored.contains("150"), "billing figures are never persisted to the app group")
        XCTAssertTrue(stored.contains("usageOnly.noDocumentedAllowance"))
    }

    func testErrorsNeverCarryTheTokenOrProviderBody() async {
        let (service, _, _) = makeService(respond: { request in
            throw ServiceError.apiError("boom \(request.value(forHTTPHeaderField: "Authorization") ?? "") {\"raw\":1}")
        })

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected a failure")
        } catch {
            let text = ServiceSupport.safeErrorMessage(for: error)
            XCTAssertFalse(text.contains("github_pat_secret_value"))
            XCTAssertFalse(text.contains("raw"))
        }
    }

    func testMalformedBillingPayloadIsAParsingError() async {
        let (service, _, _) = makeService(respond: { _ in Data(#"{"nothing":"useful"}"#.utf8) })

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("expected a parsing error")
        } catch ServiceError.parsingError {
            XCTAssertTrue(service.hasAccess, "drift is not a credential problem")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: Private

    private final nonisolated class Recorder: @unchecked Sendable {

        // MARK: Internal

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func record(_ request: URLRequest) {
            lock.lock()
            stored.append(request)
            lock.unlock()
        }

        // MARK: Private

        private let lock = NSLock()
        private var stored: [URLRequest] = []

    }

    private static let creditsPath = "/users/octocat/settings/billing/ai_credit/usage"
    private static let premiumPath = "/users/octocat/settings/billing/premium_request/usage"
    private static let budgetsPath = "/organizations/acme/settings/billing/budgets"

    private static let creditUsage = Data(#"""
    {"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[
      {"unitType":"ai-credits","grossQuantity":150,"discountQuantity":60,"netQuantity":90,"netAmount":0.9}]}
    """#.utf8)
    private static let emptyUsage = Data(#"{"timePeriod":{"year":2026},"user":"octocat","usageItems":[]}"#.utf8)
    private static let premiumUsage = Data(#"""
    {"usageItems":[{"unitType":"requests","grossQuantity":40,"discountQuantity":0,"netQuantity":40,"netAmount":1.6}]}
    """#.utf8)
    private static let budgetPage = Data(#"""
    {"budgets":[{"id":"b1","budget_type":"BundlePricing","budget_product_sku":"ai_credits","budget_scope":"user",
                 "budget_amount":25,"prevent_further_usage":true,"user":"octocat","consumed_amount":9.5}],
     "user":"octocat","effective_budget":{"id":"b1","budget_amount":25,"consumed_amount":9.5},
     "has_next_page":false,"total_count":1}
    """#.utf8)

    /// 2026-09-29 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_790_683_200)
    private var settingsDirectory: URL!

    private var organization: GitHubCopilotAccountConfig {
        GitHubCopilotAccountConfig(scope: .organization, username: "octocat", organization: "acme")
    }

    private nonisolated static func route(
        _ table: [String: Result<Data, ServiceError>]
    ) -> @Sendable (URLRequest) throws -> Data {
        { request in
            let path = request.url?.path ?? ""
            guard let result = table[path] else {
                throw ServiceError.apiError("HTTP 404")
            }
            return try result.get()
        }
    }

    private func makeService(
        config: GitHubCopilotAccountConfig = GitHubCopilotAccountConfig(username: "octocat"),
        token: String? = "github_pat_secret_value",
        recorder: Recorder = Recorder(),
        respond: @escaping @Sendable (URLRequest) throws -> Data
    ) -> (service: GitHubCopilotService, recorder: Recorder, keychain: KeychainManager) {
        let keychain = KeychainManager(
            backend: SeededKeychainBackend(),
            currentService: "test.copilot.\(UUID().uuidString)",
            legacyServices: []
        )
        if let token {
            XCTAssertTrue(keychain.save(key: GitHubCopilotService.keychainKey, value: token))
        }
        let now = now
        let service = GitHubCopilotService(
            keychain: keychain,
            fetchData: { request in
                recorder.record(request)
                return try respond(request)
            },
            configuration: config,
            settingsDirectory: settingsDirectory,
            now: { now }
        )
        return (service, recorder, keychain)
    }

}
