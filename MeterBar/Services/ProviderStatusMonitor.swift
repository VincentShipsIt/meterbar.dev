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
    /// Set when the status page was reached but its health could not be read
    /// (bot challenge, browser-rendered page). Such a report says nothing about
    /// the provider, so it never counts as an issue.
    var unreadableReason: String?

    var displayName: String {
        service.statusPageDisplayName
    }

    var isUnreadable: Bool {
        unreadableReason != nil
    }

    var headline: String {
        isUnreadable ? "Unchecked" : summary.indicator.summaryLabel
    }

    var hasIssue: Bool {
        guard !isUnreadable else { return false }
        return summary.indicator.hasIssue || components.contains { $0.hasIssue }
    }
}

/// The status page answered, but with something other than status data: a bot
/// challenge or a page that only renders in a browser. Surfaced as an
/// unreadable report rather than an outage or a parse failure.
struct ProviderStatusPageUnreadable: Error, Equatable {
    let reason: String
}

enum ProviderStatusPageGuard {
    private static let challengeMarkers = [
        "attention required! | cloudflare",
        "just a moment...",
        "cf-chl",
        "cf-browser-verification",
        "enable javascript and cookies to continue"
    ]

    static func blockedReason(for response: URLResponse, data: Data, pageName: String) -> String? {
        guard let http = response as? HTTPURLResponse else { return nil }
        let mitigated = http.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge"
        let body = String(decoding: data.prefix(64 * 1024), as: UTF8.self).lowercased()
        let hasChallengeMarker = challengeMarkers.contains { body.contains($0) }
        let fromEdgeNetwork = http.value(forHTTPHeaderField: "cf-ray") != nil
            || http.value(forHTTPHeaderField: "x-amz-cf-id") != nil
            || (http.value(forHTTPHeaderField: "server")?.lowercased().contains("cloudflare") ?? false)

        let blocked: Bool
        switch http.statusCode {
        case 403, 429:
            blocked = mitigated || hasChallengeMarker || fromEdgeNetwork
        case 503:
            blocked = mitigated || hasChallengeMarker
        default:
            blocked = mitigated || (hasChallengeMarker && (200...299).contains(http.statusCode))
        }
        guard blocked else { return nil }
        return "\(pageName) blocked MeterBar's automated status check, so its live status can't be shown here. "
            + "Open the status page in your browser."
    }

    /// True when the document carries no visible text outside `<head>`,
    /// `<script>` and `<style>` — a client-rendered shell with no status data.
    static func isScriptRenderedShell(html: String) -> Bool {
        var body = html
        if let bodyStart = body.range(of: "<body", options: .caseInsensitive) {
            body = String(body[bodyStart.lowerBound...])
        } else if let headEnd = body.range(of: "</head>", options: .caseInsensitive) {
            body = String(body[headEnd.upperBound...])
        } else {
            return false
        }
        for tag in ["script", "style", "noscript"] {
            body = body.replacingOccurrences(
                of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        let text = body
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty
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
            return "Healthy"
        case .minor:
            return "Degraded"
        case .major:
            return "Outage"
        case .critical:
            return "Down"
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
            return "Healthy"
        case "degraded_performance":
            return "Degraded"
        case "partial_outage":
            return "Outage"
        case "major_outage", "full_outage":
            return "Down"
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
            // Grok's status page is operated under the SpaceXAI brand.
            return "SpaceXAI"
        case .kimiCode:
            return "Kimi Code"
        case .zaiCodingPlan:
            return "Z.ai"
        case .githubCopilot:
            return "GitHub"
        case .museCode:
            return "Muse Code"
        case .claudePlatform:
            return "Claude Platform"
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
        case .githubCopilot:
            // Copilot is a component of GitHub's own Statuspage.
            return "https://www.githubstatus.com/"
        case .kimiCode, .zaiCodingPlan, .museCode, .claudePlatform:
            // No verified first-party status page; `hasStatusPage` keeps this
            // out of every status surface and the monitor never polls it.
            return ""
        }
    }

    var statusPageURL: URL? {
        hasStatusPage ? URL(string: statusPageURLString) : nil
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
        do {
            return try await loadReport(for: service)
        } catch let unreadable as ProviderStatusPageUnreadable {
            guard let url = service.statusPageURL else { throw ServiceError.invalidURL }
            return ProviderStatusReport(
                service: service,
                pageName: service.statusPageDisplayName,
                pageURL: url,
                summary: ProviderStatusSummary(indicator: .unknown, description: nil, updatedAt: nil),
                components: [],
                fetchedAt: Date(),
                unreadableReason: unreadable.reason
            )
        }
    }

    private func loadReport(for service: ServiceType) async throws -> ProviderStatusReport {
        if service == .openRouter {
            return try await fetchOpenRouterReport()
        }
        if service == .grok {
            return try await fetchSpaceXAIReport()
        }
        guard let baseURL = service.statusPageURL else {
            throw ServiceError.invalidURL
        }

        let parsedStatus = try await fetchStatus(from: baseURL, pageName: service.statusPageDisplayName)
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
        let (data, response) = try await fetch(from: url)
        try validatePage(response, data: data, pageName: "OpenRouter")
        guard let html = String(data: data, encoding: .utf8) else {
            throw ServiceError.parsingError(nil)
        }
        let operational = html.localizedCaseInsensitiveContains("All Systems Operational")
        // status.openrouter.ai now serves an empty shell that renders in the
        // browser, so there is no text to read and no public feed to fall back on.
        if !operational, ProviderStatusPageGuard.isScriptRenderedShell(html: html) {
            throw ProviderStatusPageUnreadable(
                reason: "OpenRouter's status page only renders in a browser and publishes no feed MeterBar "
                    + "can read. Open the status page to see current status."
            )
        }
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

    /// status.x.ai is not Statuspage — see `SpaceXAIStatusPageParser`.
    private func fetchSpaceXAIReport() async throws -> ProviderStatusReport {
        guard let url = ServiceType.grok.statusPageURL else {
            throw ServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await fetch(request)
        try validatePage(response, data: data, pageName: ServiceType.grok.statusPageDisplayName)
        guard let html = String(data: data, encoding: .utf8) else {
            throw ServiceError.parsingError(nil)
        }
        let parsed = try SpaceXAIStatusPageParser.parse(html: html)
        return ProviderStatusReport(
            service: .grok,
            pageName: ServiceType.grok.statusPageDisplayName,
            pageURL: url,
            summary: parsed.summary,
            components: parsed.components,
            fetchedAt: Date()
        )
    }

    /// `ServiceSupport.validate`, except a bot challenge or edge-network block
    /// becomes `ProviderStatusPageUnreadable` instead of a generic HTTP error.
    private func validatePage(_ response: URLResponse, data: Data, pageName: String) throws {
        if let reason = ProviderStatusPageGuard.blockedReason(for: response, data: data, pageName: pageName) {
            throw ProviderStatusPageUnreadable(reason: reason)
        }
        try ServiceSupport.validate(response, data: data)
    }

    private func fetchStatus(
        from baseURL: URL,
        pageName: String
    ) async throws -> (pageName: String?, summary: ProviderStatusSummary) {
        let url = baseURL.appendingPathComponent("api/v2/status.json")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await fetch(request)
        try validatePage(response, data: data, pageName: pageName)
        return try ProviderStatusFeedParser.parseStatuspageStatus(data: data)
    }

    private func fetchComponents(from baseURL: URL) async throws -> [ProviderStatusComponent] {
        let url = baseURL.appendingPathComponent("api/v2/components.json")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await fetch(request)
        try ServiceSupport.validate(response, data: data)
        return try ProviderStatusFeedParser.parseStatuspageComponents(data: data)
    }

    /// `URLSession.data` must not run as a main-actor job — see
    /// `ServiceSupport.detached` for the SIGSEGV rationale. Launch calls
    /// `refreshAllIfNeeded`, which fans these fetches out.
    private func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let session = session
        return try await ServiceSupport.detached(priority: .utility) {
            try await ServiceSupport.data(for: request, session: session)
        }
    }

    private func fetch(from url: URL) async throws -> (Data, URLResponse) {
        try await fetch(URLRequest(url: url))
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

    func refreshAll(services: [ServiceType] = ServiceType.statusPageServices) async {
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
