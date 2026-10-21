import Foundation

/// Account identity has a validated UUID representation; labels never become keys.
public struct AccountID: Hashable, Sendable {
    public let value: UUID

    public init(_ value: UUID) {
        self.value = value
    }

    public init?(_ value: String) {
        guard let uuid = UUID(uuidString: value) else { return nil }
        self.init(uuid)
    }
}

/// Provider-wide data is an explicit scope, never a missing account fallback.
public struct ProviderAccount: Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        case account(AccountID)
        case providerWide
    }

    public let service: ServiceType
    public let scope: Scope

    public init(service: ServiceType, scope: Scope) {
        self.service = service
        self.scope = scope
    }
}
