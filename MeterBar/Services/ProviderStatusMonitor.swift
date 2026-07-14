import Combine
import Foundation
import MeterBarShared

struct ProviderStatusSummary: Equatable {
    let indicator: ProviderStatusIndicator
    let description: String?
    let updatedAt: Date?
}

struct ProviderStatusReport: Identifiable, Equatable {
    var id: ServiceType { service }

    let service: ServiceType
    let pageName: String
    let pageURL: URL
    let summary: ProviderStatusSummary
    let components: [ProviderStatusComponent]
    let fetchedAt: Date

    var displayName: String {
        service.statusPageDisplayName
    }

    var hasIssue: Bool {
        summary.indicator.hasIssue || components.contains { $0.hasIssue }
    }
}

enum ProviderStatusIndicator: String, Codable, Equatable {
    case none
    case minor
    case major
    case critical
    case maintenance
    case unknown

    var hasIssue: Bool {
        switch self {
        case .none:
            return false
        case .minor, .major, .critical, .maintenance, .unknown:
            return true
        }
    }

    var summaryLabel: String {
        switch self {
        case .none:
            return "Operational"
        case .minor:
            return "Partial Degradation"
        case .major:
            return "Major Outage"
        case .critical:
            return "Critical Issue"
        case .maintenance:
            return "Maintenance"
        case .unknown:
            return "Unknown"
        }
    }

    var rank: Int {
        switch self {
        case .none:
            return 0
        case .maintenance, .unknown:
            return 1
        case .minor:
            return 2
        case .major:
            return 3
        case .critical:
            return 4
        }
    }

    static func statuspageIndicator(_ rawValue: String) -> ProviderStatusIndicator {
        ProviderStatusIndicator(rawValue: rawValue) ?? .unknown
    }

    static func componentIndicator(for status: String) -> ProviderStatusIndicator {
        switch status {
        case "operational":
            return .none
        case "degraded_performance":
            return .minor
        case "partial_outage":
            return .major
        case "major_outage", "full_outage":
            return .critical
        case "under_maintenance":
            return .maintenance
        default:
            return .unknown
        }
    }
}

struct ProviderStatusComponent: Identifiable, Equatable {
    let id: String
    let name: String
    let indicator: ProviderStatusIndicator
    let status: String
    var children: [ProviderStatusComponent] = []

    var isGroup: Bool {
        !children.isEmpty
    }

    var hasIssue: Bool {
        indicator.hasIssue || children.contains { $0.hasIssue }
    }

    var statusLabel: String {
        Self.label(forStatuspageStatus: status)
    }

    static func label(forStatuspageStatus status: String) -> String {
        switch status {
        case "operational":
            return "Operational"
        case "degraded_performance":
            return "Degraded"
        case "partial_outage":
            return "Partial Outage"
        case "major_outage", "full_outage":
            return "Major Outage"
        case "under_maintenance":
            return "Maintenance"
        default:
            return "Unknown"
        }
    }
}

extension ServiceType {
    var statusPageDisplayName: String {
        switch self {
        case .claudeCode:
            return "Claude"
        case .codexCli:
            return "OpenAI"
        case .cursor:
            return "Cursor"
        case .openRouter:
            return "OpenRouter"
        case .grok:
            return "Grok"
        }
    }

    var statusPageURLString: String {
        switch self {
        case .claudeCode:
            return "https://status.claude.com/"
        case .codexCli:
            return "https://status.openai.com/"
        case .cursor:
            return "https://status.cursor.com/"
        case .openRouter:
            return "https://status.openrouter.ai/"
        case .grok:
            return "https://status.x.ai/"
        }
    }

    var statusPageURL: URL? {
        URL(string: statusPageURLString)
    }
}

enum ProviderStatusFeedParser {
    static func parseStatuspageStatus(data: Data) throws -> (pageName: String?, summary: ProviderStatusSummary) {
        struct Response: Decodable {
            struct Page: Decodable {
                let name: String?
                let updatedAt: Date?

                private enum CodingKeys: String, CodingKey {
                    case name
                    case updatedAt = "updated_at"
                }
            }

            struct Status: Decodable {
                let indicator: String
                let description: String?
            }

            let page: Page?
            let status: Status
        }

        let response = try statusDecoder.decode(Response.self, from: data)
        let summary = ProviderStatusSummary(
            indicator: .statuspageIndicator(response.status.indicator),
            description: response.status.description,
            updatedAt: response.page?.updatedAt
        )
        return (response.page?.name, summary)
    }

    static func parseStatuspageComponents(data: Data) throws -> [ProviderStatusComponent] {
        struct Response: Decodable {
            struct Component: Decodable {
                let id: String
                let name: String
                let status: String
                let group: Bool?
                let groupID: String?
                let position: Int?

                private enum CodingKeys: String, CodingKey {
                    case id
                    case name
                    case status
                    case group
                    case position
                    case groupID = "group_id"
                }
            }

            let components: [Component]?
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        let components = (response.components ?? [])
            .filter { normalizedName($0.name) != nil }
            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }

        func makeRow(_ component: Response.Component, children: [ProviderStatusComponent]) -> ProviderStatusComponent {
            ProviderStatusComponent(
                id: component.id,
                name: normalizedName(component.name) ?? component.name,
                indicator: .componentIndicator(for: component.status),
                status: component.status,
                children: children
            )
        }

        var childrenByGroup: [String: [ProviderStatusComponent]] = [:]
        for component in components where component.group != true {
            guard let groupID = component.groupID else { continue }
            childrenByGroup[groupID, default: []].append(makeRow(component, children: []))
        }

        return components.compactMap { component in
            if component.group == true {
                return makeRow(component, children: childrenByGroup[component.id] ?? [])
            }
            if component.groupID != nil {
                return nil
            }
            return makeRow(component, children: [])
        }
    }

    private static var statusDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            guard let date = FlexibleISO8601.date(from: rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO8601 date"
                )
            }
            return date
        }
        return decoder
    }

    private static func normalizedName(_ name: String?) -> String? {
        guard let value = name?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

struct ProviderStatusClient {
    let session: URLSession

    func fetchReport(for service: ServiceType) async throws -> ProviderStatusReport {
        if service == .openRouter {
            return try await fetchOpenRouterReport()
        }
        guard let baseURL = service.statusPageURL else {
            throw ServiceError.invalidURL
        }

        let parsedStatus = try await fetchStatus(from: baseURL)
        let components = (try? await fetchComponents(from: baseURL)) ?? []
        return ProviderStatusReport(
            service: service,
            pageName: parsedStatus.pageName ?? service.statusPageDisplayName,
            pageURL: baseURL,
            summary: parsedStatus.summary,
            components: components,
            fetchedAt: Date()
        )
    }

    private func fetchOpenRouterReport() async throws -> ProviderStatusReport {
        guard let url = ServiceType.openRouter.statusPageURL else {
            throw ServiceError.invalidURL
        }
        let (data, response) = try await session.data(from: url)
        try ServiceSupport.validate(response, data: data)
        guard let html = String(data: data, encoding: .utf8) else {
            throw ServiceError.parsingError
        }
        let operational = html.localizedCaseInsensitiveContains("All Systems Operational")
        return ProviderStatusReport(
            service: .openRouter,
            pageName: "OpenRouter",
            pageURL: url,
            summary: ProviderStatusSummary(
                indicator: operational ? .none : .unknown,
                description: operational ? "All Systems Operational" : "Check the OpenRouter status page",
                updatedAt: nil
            ),
            components: [],
            fetchedAt: Date()
        )
    }

    private func fetchStatus(
        from baseURL: URL
    ) async throws -> (pageName: String?, summary: ProviderStatusSummary) {
        let url = baseURL.appendingPathComponent("api/v2/status.json")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        try ServiceSupport.validate(response, data: data)
        return try ProviderStatusFeedParser.parseStatuspageStatus(data: data)
    }

    private func fetchComponents(from baseURL: URL) async throws -> [ProviderStatusComponent] {
        let url = baseURL.appendingPathComponent("api/v2/components.json")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        try ServiceSupport.validate(response, data: data)
        return try ProviderStatusFeedParser.parseStatuspageComponents(data: data)
    }
}

@MainActor
final class ProviderStatusMonitor: ObservableObject {
    static let shared = ProviderStatusMonitor()

    @Published private(set) var reports: [ServiceType: ProviderStatusReport] = [:]
    @Published private(set) var errors: [ServiceType: String] = [:]
    @Published private(set) var isRefreshing = false

    private let client: ProviderStatusClient
    private var lastRefresh: Date?
    private let freshnessWindow: TimeInterval = 5 * 60

    init(client: ProviderStatusClient? = nil) {
        self.client = client ?? ProviderStatusClient(session: ServiceSupport.session)
    }

    func refreshAllIfNeeded() async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < freshnessWindow {
            return
        }
        await refreshAll()
    }

    func refreshAll(services: [ServiceType] = ServiceType.allCases) async {
        guard !isRefreshing else { return }
        isRefreshing = true

        let client = self.client
        await withTaskGroup(of: (ServiceType, Result<ProviderStatusReport, Error>).self) { group in
            for service in services {
                group.addTask {
                    do {
                        return (service, .success(try await client.fetchReport(for: service)))
                    } catch {
                        return (service, .failure(error))
                    }
                }
            }

            for await (service, result) in group {
                switch result {
                case .success(let report):
                    reports[service] = report
                    errors.removeValue(forKey: service)
                case .failure(let error):
                    reports.removeValue(forKey: service)
                    errors[service] = ProviderStatusMonitor.message(for: error)
                }
            }
        }

        lastRefresh = Date()
        isRefreshing = false
    }

    private static func message(for error: Error) -> String {
        if let serviceError = error as? ServiceError {
            return serviceError.localizedDescription
        }
        if let urlError = error as? URLError {
            return ServiceSupport.message(for: urlError)
        }
        if error is DecodingError {
            return "Failed to parse status feed"
        }
        return error.localizedDescription
    }
}
