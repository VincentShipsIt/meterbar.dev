import Foundation

/// Wraps a decodable value so one bad element degrades to `nil` instead of
/// failing the containing collection's decode.
///
/// Swift's keyed and unkeyed containers advance past an element whose nested
/// decode throws, so wrapping the element type is enough to make an array or
/// dictionary tolerant: the unreadable entries become `nil` and every entry the
/// running build understands survives. Persisted caches read across app
/// versions — the App Group blobs, the provider usage ledger — decode through
/// this rather than an all-or-nothing `try?`.
public struct FailableBox<T: Decodable>: Decodable {
    public let value: T?

    public init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
