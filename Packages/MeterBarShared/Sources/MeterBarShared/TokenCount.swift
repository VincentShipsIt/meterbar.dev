import Foundation

/// Non-negative tokens. Addition saturates so an upstream counter cannot trap
/// a later fold. The wire representation remains a single integer.
public struct TokenCount: Codable, Hashable, Sendable, Comparable {
    public let value: Int

    public init(_ value: Int) {
        self.value = max(0, value)
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        let (sum, overflow) = lhs.value.addingReportingOverflow(rhs.value)
        return Self(overflow ? .max : sum)
    }

    public static func += (lhs: inout Self, rhs: Self) {
        lhs = Self((lhs + rhs).value)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Int.self)
        guard value >= 0 else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Negative token count")
        }
        self.init(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
