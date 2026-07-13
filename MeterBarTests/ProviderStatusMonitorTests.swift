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
        XCTAssertEqual(components[1].statusLabel, "Operational")
    }

    func testServiceTypeStatusPageURLs() throws {
        XCTAssertEqual(ServiceType.claudeCode.statusPageDisplayName, "Claude")
        XCTAssertEqual(ServiceType.codexCli.statusPageDisplayName, "OpenAI")
        XCTAssertEqual(ServiceType.cursor.statusPageDisplayName, "Cursor")
        XCTAssertEqual(ServiceType.openRouter.statusPageDisplayName, "OpenRouter")

        XCTAssertEqual(try XCTUnwrap(ServiceType.claudeCode.statusPageURL).absoluteString, "https://status.claude.com/")
        XCTAssertEqual(try XCTUnwrap(ServiceType.codexCli.statusPageURL).absoluteString, "https://status.openai.com/")
        XCTAssertEqual(try XCTUnwrap(ServiceType.cursor.statusPageURL).absoluteString, "https://status.cursor.com/")
        XCTAssertEqual(
            try XCTUnwrap(ServiceType.openRouter.statusPageURL).absoluteString,
            "https://status.openrouter.ai/"
        )
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
}
