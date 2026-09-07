import Foundation
import MeterBarShared
@testable import MeterBar
import XCTest

final class ProviderStatusMonitorTests: XCTestCase {
    private final class StubURLProtocol: URLProtocol {
        static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }

            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testParsesStatuspageSummary() throws {
        let json = """
        {
          "page": {
            "name": "OpenAI",
            "updated_at": "2026-07-09T14:48:49.467Z"
          },
          "status": {
            "indicator": "minor",
            "description": "Partial System Degradation"
          }
        }
        """

        let parsed = try ProviderStatusFeedParser.parseStatuspageStatus(data: Data(json.utf8))

        XCTAssertEqual(parsed.pageName, "OpenAI")
        XCTAssertEqual(parsed.summary.indicator, .minor)
        XCTAssertEqual(parsed.summary.description, "Partial System Degradation")
        XCTAssertNotNil(parsed.summary.updatedAt)
    }

    func testParsesStatuspageComponentsAndGroupsChildren() throws {
        let json = """
        {
          "components": [
            {
              "id": "group-api",
              "name": "APIs",
              "status": "degraded_performance",
              "group": true,
              "position": 1
            },
            {
              "id": "chat",
              "name": "ChatGPT",
              "status": "operational",
              "group": false,
              "position": 2
            },
            {
              "id": "responses",
              "name": "Responses API",
              "status": "partial_outage",
              "group": false,
              "group_id": "group-api",
              "position": 3
            }
          ]
        }
        """

        let components = try ProviderStatusFeedParser.parseStatuspageComponents(data: Data(json.utf8))

        XCTAssertEqual(components.count, 2)
        XCTAssertEqual(components[0].name, "APIs")
        XCTAssertTrue(components[0].isGroup)
        XCTAssertEqual(components[0].indicator, .minor)
        XCTAssertEqual(components[0].children.map(\.name), ["Responses API"])
        XCTAssertEqual(components[0].children.first?.indicator, .major)
        XCTAssertEqual(components[1].name, "ChatGPT")
        XCTAssertEqual(components[1].statusLabel, "Healthy")
    }

    func testProviderStatusLabelsStayCompact() {
        XCTAssertEqual(ProviderStatusIndicator.none.summaryLabel, "Healthy")
        XCTAssertEqual(ProviderStatusIndicator.minor.summaryLabel, "Degraded")
        XCTAssertEqual(ProviderStatusIndicator.major.summaryLabel, "Outage")
        XCTAssertEqual(ProviderStatusIndicator.critical.summaryLabel, "Down")
        XCTAssertEqual(ProviderStatusIndicator.maintenance.summaryLabel, "Maintenance")
        XCTAssertEqual(ProviderStatusIndicator.unknown.summaryLabel, "Unknown")

        XCTAssertEqual(ProviderStatusComponent.label(forStatuspageStatus: "operational"), "Healthy")
        XCTAssertEqual(ProviderStatusComponent.label(forStatuspageStatus: "partial_outage"), "Outage")
        XCTAssertEqual(ProviderStatusComponent.label(forStatuspageStatus: "major_outage"), "Down")
    }

    func testServiceTypeStatusPageURLs() throws {
        XCTAssertEqual(ServiceType.claudeCode.statusPageDisplayName, "Claude")
        XCTAssertEqual(ServiceType.codexCli.statusPageDisplayName, "OpenAI")
        XCTAssertEqual(ServiceType.cursor.statusPageDisplayName, "Cursor")
        XCTAssertEqual(ServiceType.openRouter.statusPageDisplayName, "OpenRouter")
        XCTAssertEqual(ServiceType.grok.statusPageDisplayName, "SpaceXAI")

        XCTAssertEqual(try XCTUnwrap(ServiceType.claudeCode.statusPageURL).absoluteString, "https://status.claude.com/")
        XCTAssertEqual(try XCTUnwrap(ServiceType.codexCli.statusPageURL).absoluteString, "https://status.openai.com/")
        XCTAssertEqual(try XCTUnwrap(ServiceType.cursor.statusPageURL).absoluteString, "https://status.cursor.com/")
        XCTAssertEqual(
            try XCTUnwrap(ServiceType.openRouter.statusPageURL).absoluteString,
            "https://status.openrouter.ai/"
        )
        XCTAssertEqual(try XCTUnwrap(ServiceType.grok.statusPageURL).absoluteString, "https://status.x.ai/")
    }

    func testOpenRouterStatusPageMapsOperationalHTML() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = ProviderStatusClient(session: URLSession(configuration: configuration))

        StubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, Data("<h1>All Systems Operational</h1>".utf8))
        }

        let report = try await client.fetchReport(for: .openRouter)

        XCTAssertEqual(report.service, .openRouter)
        XCTAssertEqual(report.summary.indicator, .none)
        XCTAssertFalse(report.hasIssue)
    }

    /// Launch calls `refreshAllIfNeeded` on the main actor, which fans
    /// `ProviderStatusClient.fetchReport` through a task group. 1.8.39 SIGSEGV'd
    /// entering `NSURLSession.data` on that hop; the network leg is now detached.
    func testFetchReportFromMainActorDoesNotCrashEnteringURLSessionData() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = ProviderStatusClient(session: URLSession(configuration: configuration))

        StubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, Data("<h1>All Systems Operational</h1>".utf8))
        }

        let report = try await client.fetchReport(for: .openRouter)
        XCTAssertEqual(report.summary.indicator, .none)
    }

    @MainActor
    func testRefreshFailureClearsPreviouslySuccessfulReport() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let monitor = ProviderStatusMonitor(
            client: ProviderStatusClient(session: URLSession(configuration: configuration))
        )

        StubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let data: Data
            if request.url?.lastPathComponent == "status.json" {
                data = Data(
                    #"{"page":{"name":"Claude"},"status":{"indicator":"none","description":"Operational"}}"#
                        .utf8
                )
            } else {
                data = Data(#"{"components":[]}"#.utf8)
            }
            return (response, data)
        }

        await monitor.refreshAll(services: [.claudeCode])
        XCTAssertNotNil(monitor.reports[.claudeCode])
        XCTAssertNil(monitor.errors[.claudeCode])

        StubURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        await monitor.refreshAll(services: [.claudeCode])
        XCTAssertNil(monitor.reports[.claudeCode])
        XCTAssertNotNil(monitor.errors[.claudeCode])
    }

    // MARK: - SpaceXAI (status.x.ai)

    /// status.x.ai is a custom Next.js page, not Atlassian Statuspage — its
    /// `api/v2/status.json` is a 404 HTML page. Service state is server-rendered
    /// as one `<a>` card per service with a coloured chip.
    private static let spaceXAIHealthyHTML = """
    <html><body><main class="grow"><h1 class="title">Service Status</h1>
    <section class="mt-8"><div class="card"><div class="flex flex-col grow">
    <h3 class="heading-3">No incidents declared</h3>
    <p class="text-text-secondary">We are not actively mitigating any known incidents at this time.</p>
    </div></div></section>
    <section class="space-y-6 mt-10"><h2 class="subtitle">Services</h2><div class="grid">
    <a class="w-full card" href="/ios-app"><div class="flex"><div class="heading-2">Grok (iOS)</div></div>\
    <div class="shrink-0 capitalize bg-status-success/20 border-status-success/20 text-text-success">available</div></a>
    <a class="w-full card" href="/grok-com"><div class="flex"><div class="heading-2">Grok (Web)</div></div>\
    <div class="shrink-0 capitalize bg-status-success/20 border-status-success/20 text-text-success">available</div></a>
    <a class="w-full card" href="/grok-build"><div class="flex"><div class="heading-2">Grok Build</div></div>\
    <div class="shrink-0 capitalize bg-status-success/20 border-status-success/20 text-text-success">available</div></a>
    <a class="w-full card" href="/api-us-east-1"><div class="flex">\
    <div class="heading-2">API (us-east-1.api.x.ai)</div></div>\
    <div class="shrink-0 capitalize bg-status-success/20 border-status-success/20 text-text-success">available</div></a>
    </div></section></main></body></html>
    """

    private static let spaceXAIIncidentHTML = """
    <html><body><main class="grow"><h1 class="title">Service Status</h1>
    <section class="mt-8"><div class="card"><div class="flex flex-col grow">
    <h3 class="heading-3">Active incidents</h3>
    <p class="text-text-secondary">We are investigating an issue with our models.</p>
    </div></div></section>
    <section class="space-y-6 mt-10"><h2 class="subtitle">Services</h2><div class="grid">
    <a class="w-full card" href="/grok-com"><div class="flex"><div class="heading-2">Grok (Web)</div></div>\
    <div class="shrink-0 capitalize bg-status-danger/20 border-status-danger/20 text-text-danger">outage</div></a>
    <a class="w-full card" href="/grok-build"><div class="flex"><div class="heading-2">Grok Build</div></div>\
    <div class="shrink-0 capitalize bg-status-caution/20 border-status-caution/20 text-text-caution">degraded</div></a>
    <a class="w-full card" href="/api-console"><div class="flex"><div class="heading-2">API Console</div></div>\
    <div class="shrink-0 capitalize bg-status-info/20 border-status-info/20 text-text-info">maintenance</div></a>
    <a class="w-full card" href="/docs"><div class="flex"><div class="heading-2">Docs</div></div>\
    <div class="shrink-0 capitalize bg-status-unavailable/20 text-text-unavailable">unavailable</div></a>
    <a class="w-full card" href="/ios-app"><div class="flex"><div class="heading-2">Grok (iOS)</div></div>\
    <div class="shrink-0 capitalize bg-status-success/20 border-status-success/20 text-text-success">available</div></a>
    </div></section></main></body></html>
    """

    func testParsesSpaceXAIStatusPageWhenHealthy() throws {
        let parsed = try SpaceXAIStatusPageParser.parse(html: Self.spaceXAIHealthyHTML)

        XCTAssertEqual(parsed.summary.indicator, .none)
        XCTAssertEqual(parsed.summary.description, "No incidents declared")
        XCTAssertEqual(
            parsed.components.map(\.name),
            ["Grok (iOS)", "Grok (Web)", "Grok Build", "API (us-east-1.api.x.ai)"]
        )
        XCTAssertEqual(parsed.components.map(\.id), ["ios-app", "grok-com", "grok-build", "api-us-east-1"])
        XCTAssertTrue(parsed.components.allSatisfy { $0.indicator == .none })
        XCTAssertTrue(parsed.components.allSatisfy { $0.statusLabel == "Healthy" })
        XCTAssertFalse(parsed.components.contains { $0.hasIssue })
    }

    func testParsesSpaceXAIStatusPageWithIncident() throws {
        let parsed = try SpaceXAIStatusPageParser.parse(html: Self.spaceXAIIncidentHTML)

        // The headline is not "No incidents declared", so the worst chip wins.
        XCTAssertEqual(parsed.summary.indicator, .critical)
        XCTAssertEqual(parsed.summary.description, "Active incidents")

        let byID = Dictionary(uniqueKeysWithValues: parsed.components.map { ($0.id, $0) })
        XCTAssertEqual(byID["grok-com"]?.indicator, .major)
        XCTAssertEqual(byID["grok-com"]?.statusLabel, "Outage")
        XCTAssertEqual(byID["grok-build"]?.indicator, .minor)
        XCTAssertEqual(byID["grok-build"]?.statusLabel, "Degraded")
        XCTAssertEqual(byID["api-console"]?.indicator, .maintenance)
        XCTAssertEqual(byID["api-console"]?.statusLabel, "Maintenance")
        XCTAssertEqual(byID["docs"]?.indicator, .critical)
        XCTAssertEqual(byID["docs"]?.statusLabel, "Down")
        XCTAssertEqual(byID["ios-app"]?.indicator, ProviderStatusIndicator.none)
    }

    func testSpaceXAIStatusPageWithoutServicesIsParsingError() {
        let blocked = "<html><body>Attention Required!</body></html>"
        XCTAssertThrowsError(try SpaceXAIStatusPageParser.parse(html: blocked)) { error in
            guard case ServiceError.parsingError = error else {
                return XCTFail("Expected parsingError, got \(error)")
            }
        }
    }

    func testGrokReportReadsSpaceXAIStatusPageNotStatuspageJSON() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = ProviderStatusClient(session: URLSession(configuration: configuration))

        let requestedPaths = LockedBox<[String]>([])
        StubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            requestedPaths.mutate { $0.append(url.path) }
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, Data(Self.spaceXAIHealthyHTML.utf8))
        }

        let report = try await client.fetchReport(for: .grok)

        XCTAssertEqual(requestedPaths.value, ["/"])
        XCTAssertEqual(report.service, .grok)
        XCTAssertEqual(report.pageName, "SpaceXAI")
        XCTAssertEqual(report.pageURL.absoluteString, "https://status.x.ai/")
        XCTAssertEqual(report.summary.indicator, .none)
        XCTAssertEqual(report.components.count, 4)
        XCTAssertFalse(report.hasIssue)
    }

    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value

        init(_ value: Value) {
            storage = value
        }

        var value: Value {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func mutate(_ body: (inout Value) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            body(&storage)
        }
    }
}
