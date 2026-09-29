import Foundation

/// Names the kind of work a route is requested for.
///
/// Task classification is explicit in version 1: the caller says
/// `--task implementation`, and MeterBar never inspects or classifies free-form
/// prompt text. Seven ids are built in, each with a safe default policy. A user
/// may add their own custom tasks; those share the same slug grammar so a task
/// id is always safe to print, persist, and pass on a command line.
public struct RoutingTaskID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public static let planning = RoutingTaskID(builtIn: "planning")
    public static let implementation = RoutingTaskID(builtIn: "implementation")
    public static let debugging = RoutingTaskID(builtIn: "debugging")
    public static let review = RoutingTaskID(builtIn: "review")
    public static let research = RoutingTaskID(builtIn: "research")
    public static let quickEdit = RoutingTaskID(builtIn: "quick-edit")
    /// The neutral, general-purpose built-in. User-named tasks start from the
    /// same neutral policy.
    public static let custom = RoutingTaskID(builtIn: "custom")

    /// Built-in tasks in the order every surface lists them.
    public static let builtIn: [RoutingTaskID] = [
        .planning, .implementation, .debugging, .review, .research, .quickEdit, .custom
    ]

    public static let maximumLength = 40

    public let rawValue: String

    private init(builtIn rawValue: String) {
        self.rawValue = rawValue
    }

    /// Parses a caller-supplied token. Tolerant of casing, surrounding
    /// whitespace, and `_` / space separators so shell interpolation does not
    /// become a usage error; `nil` when what remains is not a valid slug.
    public init?(token: String) {
        guard let normalized = Self.normalize(token) else { return nil }
        rawValue = normalized
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = RoutingTaskID(token: raw) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Not a valid routing task id."
                )
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var isBuiltIn: Bool {
        Self.builtIn.contains(self)
    }

    /// The display name a built-in task ships with; `nil` for a custom task,
    /// whose name is the user's.
    public var builtInName: String? {
        switch self {
        case .planning: return "Planning"
        case .implementation: return "Implementation"
        case .debugging: return "Debugging"
        case .review: return "Review"
        case .research: return "Research"
        case .quickEdit: return "Quick edit"
        case .custom: return "Custom"
        default: return nil
        }
    }

    public var description: String { rawValue }

    /// Built-ins first in their documented order, then custom ids alphabetically.
    public static func < (lhs: RoutingTaskID, rhs: RoutingTaskID) -> Bool {
        let lhsIndex = builtIn.firstIndex(of: lhs)
        let rhsIndex = builtIn.firstIndex(of: rhs)
        switch (lhsIndex, rhsIndex) {
        case let (lhsIndex?, rhsIndex?): return lhsIndex < rhsIndex
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return lhs.rawValue < rhs.rawValue
        }
    }

    private static func normalize(_ token: String) -> String? {
        var value = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        if value == "quickedit" { value = "quick-edit" }

        guard !value.isEmpty, value.count <= maximumLength else { return nil }
        guard !value.hasPrefix("-"), !value.hasSuffix("-"), !value.contains("--") else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard value.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }
}
