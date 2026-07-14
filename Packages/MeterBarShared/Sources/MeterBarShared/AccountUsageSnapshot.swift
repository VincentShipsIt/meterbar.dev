import Foundation

/// A labeled provider account for surfaces that can render more than one
/// account per service, such as the widget.
public struct AccountUsageSnapshot: Codable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let metrics: UsageMetrics

    public init(id: UUID, name: String, metrics: UsageMetrics) {
        self.id = id
        self.name = name
        self.metrics = metrics
    }
}
