import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class ServeRouterTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let token = "test-secret-token"

    private lazy var metrics: [ServiceType: UsageMetrics] = [
        .claudeCode: UsageMetrics(
            service: .claudeCode,
            sessionLimit: UsageLimit(used: 42.5, total: 100, resetTime: referenceDate, windowSeconds: 18_000),
            weeklyLimit: UsageLimit(used: 90, total: 100, resetTime: nil, windowSeconds: 604_800, isEstimated: true),
            extraUsage: ExtraUsageStatus(state: .on, detail: "$0.00 used"),
            lastUpdated: referenceDate
        ),
    ]

    /// Two providers whose identifiers and display names diverge, so a
    /// `?provider=` test can tell an identifier match from a display-name one.
    private lazy var multiProviderMetrics: [ServiceType: UsageMetrics] = metrics.merging([
        .codexCli: UsageMetrics(
            service: .codexCli,
            weeklyLimit: UsageLimit(used: 10, total: 100, resetTime: referenceDate),
            lastUpdated: referenceDate
        ),
    ]) { current, _ in current }

    private lazy var costCache = CostSummaryCache(
        summary: CostSummary(
            costs: [
                TokenCost(
                    provider: .codexCli,
                    inputTokens: 1_000,
                    outputTokens: 250,
                    cacheCreationTokens: 50,
                    cacheReadTokens: 500,
                    estimatedCostUSD: 1.25,
                    sessionCount: 3,
                    periodStart: referenceDate.addingTimeInterval(-86_400),
                    periodEnd: referenceDate
                ),
            ],
            totalCostUSD: 1.25,
            totalTokens: 1_800,
            periodDays: 30
        ),
        lastScanDate: referenceDate
    )

    private func makeDataSource(
        metrics: [ServiceType: UsageMetrics]? = nil,
        costCache: CostSummaryCache?? = nil
    ) -> ServeRouter.DataSource {
        let resolvedMetrics = metrics ?? self.metrics
        let resolvedCostCache = costCache ?? .some(self.costCache)
        return ServeRouter.DataSource(
            loadUsageMetrics: { resolvedMetrics },
            loadCostCache: { resolvedCostCache }
        )
    }

    private func request(
        method: String = "GET",
        path: String,
        query: [String: String] = [:],
        token providedToken: String?
    ) -> ServeHTTPRequest {
        ServeHTTPRequest(
            method: method,
            path: path,
            query: query,
            authorizationHeader: providedToken.map { "Bearer \($0)" }
        )
    }

    // MARK: Authentication

    func testMissingTokenReturnsUnauthorizedWithNoData() {
        let response = ServeRouter.handle(
            request(path: "/usage", token: nil),
            token: token,
            dataSource: makeDataSource()
        )

        XCTAssertEqual(response.status, 401)
        assertBodyContainsNoUsageData(response)
    }

    func testInvalidTokenReturnsUnauthorizedWithNoData() {
        let response = ServeRouter.handle(
            request(path: "/usage", token: "wrong-token"),
            token: token,
            dataSource: makeDataSource()
        )

        XCTAssertEqual(response.status, 401)
        assertBodyContainsNoUsageData(response)
    }

    func testUnauthenticatedRequestToUnknownPathStillReturnsUnauthorizedNotNotFound() {
        // Auth is checked before routing so an unauthenticated caller can't use
        // status codes to enumerate which paths exist.
        let response = ServeRouter.handle(
            request(path: "/does-not-exist", token: nil),
            token: token,
            dataSource: makeDataSource()
        )

        XCTAssertEqual(response.status, 401)
    }

    func testUnauthenticatedNonGetRequestStillReturnsUnauthorizedNotMethodNotAllowed() {
        let response = ServeRouter.handle(
            request(method: "POST", path: "/usage", token: nil),
            token: token,
            dataSource: makeDataSource()
        )

        XCTAssertEqual(response.status, 401)
    }

    /// A blank configured token must lock the endpoint down, not open it: the
    /// bare `Authorization: Bearer ` header a caller can trivially send would
    /// otherwise compare equal to "" and authorize everything.
    func testBlankConfiguredTokenRejectsEveryRequest() {
        for configured in ["", "   "] {
            for presented in [nil, "", " ", "anything"] as [String?] {
                let response = ServeRouter.handle(
                    request(path: "/usage", token: presented),
                    token: configured,
                    dataSource: makeDataSource()
                )

                XCTAssertEqual(
                    response.status,
                    401,
                    "configured=\(configured.debugDescription) presented=\(presented.debugDescription)"
                )
                assertBodyContainsNoUsageData(response)
            }
        }
    }

    func testErrorResponseBodyNeverContainsTheToken() throws {
        let response = ServeRouter.handle(
            request(path: "/usage", token: nil),
            token: token,
            dataSource: makeDataSource()
        )

        let body = try XCTUnwrap(String(data: response.body, encoding: .utf8))
        XCTAssertFalse(body.contains(token))
    }

    // MARK: Method and path rejection

    func testNonGetMethodWithValidTokenReturnsMethodNotAllowedWithNoData() {
        let response = ServeRouter.handle(
            request(method: "POST", path: "/usage", token: token),
            token: token,
            dataSource: makeDataSource()
        )

        XCTAssertEqual(response.status, 405)
        assertBodyContainsNoUsageData(response)
    }

    func testUnknownPathWithValidTokenReturnsNotFoundWithNoData() {
        let response = ServeRouter.handle(
            request(path: "/unknown", token: token),
            token: token,
            dataSource: makeDataSource()
        )

        XCTAssertEqual(response.status, 404)
        assertBodyContainsNoUsageData(response)
    }

    // MARK: Cache headers

    func testEveryResponseCarriesNoStoreCacheControl() {
        let responses = [
            ServeRouter.handle(request(path: "/usage", token: token), token: token, dataSource: makeDataSource()),
            ServeRouter.handle(request(path: "/cost", token: token), token: token, dataSource: makeDataSource()),
            ServeRouter.handle(request(path: "/usage", token: nil), token: token, dataSource: makeDataSource()),
            ServeRouter.handle(request(path: "/nope", token: token), token: token, dataSource: makeDataSource()),
            ServeRouter.handle(
                request(method: "POST", path: "/usage", token: token),
                token: token,
                dataSource: makeDataSource()
            ),
        ]

        for response in responses {
            XCTAssertEqual(response.headers["Cache-Control"], "no-store")
        }
    }

    // MARK: Schema stability — the served payload must be byte-identical to the CLI's own DTO output.

    func testUsageEndpointBodyMatchesUsageCLIJSONResponseExactly() throws {
        let response = ServeRouter.handle(
            request(path: "/usage", token: token),
            token: token,
            dataSource: makeDataSource()
        )

        let expected = try UsageCLIJSONResponse(metrics: metrics).jsonData()
        XCTAssertEqual(response.body, expected)
        XCTAssertEqual(response.headers["Content-Type"], "application/json; charset=utf-8")
    }

    func testCostEndpointBodyMatchesCostCLIJSONResponseExactly() throws {
        let response = ServeRouter.handle(
            request(path: "/cost", token: token),
            token: token,
            dataSource: makeDataSource()
        )

        let expected = try CostCLIJSONResponse(cache: costCache).jsonData()
        XCTAssertEqual(response.body, expected)
    }

    // MARK: `?provider=` parity with `meterbar usage --provider`

    func testUsageEndpointProviderQueryMatchesTheProviderIdentifier() throws {
        try assertUsageEndpoint(provider: "codex", selects: [.codexCli])
        try assertUsageEndpoint(provider: "CODEX", selects: [.codexCli])
    }

    /// Codex's identifier is "Codex CLI" but it is displayed as "OpenAI
    /// Codex", so "openai" can only match through the display name.
    func testUsageEndpointProviderQueryMatchesTheDisplayName() throws {
        try assertUsageEndpoint(provider: "openai", selects: [.codexCli])
    }

    /// `?provider=%20codex%20` decodes to a padded needle. The CLI trims it,
    /// so the endpoint has to as well — it used to return an empty set while
    /// `meterbar usage --provider " codex "` matched Codex.
    func testUsageEndpointTrimsAPaddedProviderQueryLikeTheCLI() throws {
        try assertUsageEndpoint(provider: " codex ", selects: [.codexCli])
        try assertUsageEndpoint(provider: "\tcodex\n", selects: [.codexCli])
    }

    func testUsageEndpointReturnsAnEmptySetWhenTheProviderQueryMatchesNothing() throws {
        try assertUsageEndpoint(provider: "clod", selects: [])
    }

    /// A missing filter selects everything, and a blank one is still no
    /// filter — the router used to treat "   " as a needle matching nothing.
    func testUsageEndpointWithoutAProviderQueryReturnsEveryCachedProvider() throws {
        try assertUsageEndpoint(provider: nil, selects: [.claudeCode, .codexCli])
        try assertUsageEndpoint(provider: "", selects: [.claudeCode, .codexCli])
        try assertUsageEndpoint(provider: "   ", selects: [.claudeCode, .codexCli])
    }

    func testCostEndpointHonorsDaysQueryLikeTheCLI() throws {
        let response = ServeRouter.handle(
            request(path: "/cost", query: ["days": "7"], token: token),
            token: token,
            dataSource: makeDataSource()
        )

        let expected = try CostCLIJSONResponse(cache: costCache, days: 7).jsonData()
        XCTAssertEqual(response.body, expected)
    }

    func testCostEndpointHonorsMonthToDateQueryLikeTheCLI() throws {
        let response = ServeRouter.handle(
            request(path: "/cost", query: ["monthToDate": "true"], token: token),
            token: token,
            dataSource: makeDataSource()
        )

        let expected = try CostCLIJSONResponse(cache: costCache, monthToDate: true).jsonData()
        XCTAssertEqual(response.body, expected)
    }

    func testCostEndpointIgnoresNonPositiveDaysQuery() throws {
        let response = ServeRouter.handle(
            request(path: "/cost", query: ["days": "0"], token: token),
            token: token,
            dataSource: makeDataSource()
        )

        let expected = try CostCLIJSONResponse(cache: costCache).jsonData()
        XCTAssertEqual(response.body, expected)
    }

    // MARK: Cache-missing parity with the CLI's own error envelope

    func testUsageEndpointReportsCacheMissingWhenNoMetricsAreCached() throws {
        let response = ServeRouter.handle(
            request(path: "/usage", token: token),
            token: token,
            dataSource: makeDataSource(metrics: [:])
        )

        XCTAssertEqual(response.status, 200)
        let expected = try CLIJSONErrorResponse(
            code: "usage_cache_missing",
            message: "No cached metrics found. Open MeterBar app to fetch data."
        ).jsonData()
        XCTAssertEqual(response.body, expected)
    }

    func testCostEndpointReportsCacheMissingWhenNoCostCacheExists() throws {
        let response = ServeRouter.handle(
            request(path: "/cost", token: token),
            token: token,
            dataSource: makeDataSource(costCache: .some(nil))
        )

        XCTAssertEqual(response.status, 200)
        let expected = try CLIJSONErrorResponse(
            code: "cost_cache_missing",
            message: "No cost data cached. Open MeterBar and run a scan (Costs tab)."
        ).jsonData()
        XCTAssertEqual(response.body, expected)
    }

    // MARK: Rate limiting

    func testTooManyRequestsResponseHasNoDataAndNoStoreHeader() {
        let response = ServeRouter.tooManyRequestsResponse()

        XCTAssertEqual(response.status, 429)
        assertBodyContainsNoUsageData(response)
        XCTAssertEqual(response.headers["Cache-Control"], "no-store")
    }

    func testMalformedRequestResponseHasNoDataAndNoStoreHeader() {
        let response = ServeRouter.malformedRequestResponse()

        XCTAssertEqual(response.status, 400)
        assertBodyContainsNoUsageData(response)
        XCTAssertEqual(response.headers["Cache-Control"], "no-store")
    }

    // MARK: Encoding failures

    /// A document that fails to encode must surface as a 500, never as an
    /// empty body wearing a `200 OK` / `application/json` label — a caller
    /// would read that as a successful response it simply can't parse.
    func testJSONResponseReportsAnEncodingFailureAsFiveHundred() throws {
        let response = ServeRouter.jsonResponse(FailingDocument())

        XCTAssertEqual(response.status, 500)
        XCTAssertFalse(response.body.isEmpty, "a 500 must still carry a parseable error body")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "internal_error")
    }

    func testErrorResponseAlwaysCarriesAParseableBody() throws {
        let response = ServeRouter.malformedRequestResponse()

        XCTAssertFalse(response.body.isEmpty)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private struct FailingDocument: CLIJSONDocument {
        struct EncodingFailure: Error {}

        func encode(to encoder: Encoder) throws {
            throw EncodingFailure()
        }
    }

    // MARK: Helpers

    /// Drives `/usage` against the two-provider fixture and asserts the body
    /// is byte-identical to the DTO the CLI would emit for `selects`.
    private func assertUsageEndpoint(
        provider: String?,
        selects selected: Set<ServiceType>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let response = ServeRouter.handle(
            request(
                path: "/usage",
                query: provider.map { ["provider": $0] } ?? [:],
                token: token
            ),
            token: token,
            dataSource: makeDataSource(metrics: multiProviderMetrics)
        )

        let expectedMetrics = multiProviderMetrics.filter { selected.contains($0.key) }
        XCTAssertEqual(expectedMetrics.count, selected.count, "fixture is missing \(selected)", file: file, line: line)

        let expected = try UsageCLIJSONResponse(metrics: expectedMetrics).jsonData()
        XCTAssertEqual(response.body, expected, "provider=\(provider.debugDescription)", file: file, line: line)
    }

    private func assertBodyContainsNoUsageData(_ response: ServeHTTPResponse, file: StaticString = #filePath, line: UInt = #line) {
        guard let body = String(data: response.body, encoding: .utf8) else {
            XCTFail("expected a UTF-8 body", file: file, line: line)
            return
        }
        XCTAssertFalse(body.contains("\"providers\""), "error body leaked provider data", file: file, line: line)
        XCTAssertFalse(body.contains("claude"), "error body leaked a provider identifier", file: file, line: line)
    }
}
