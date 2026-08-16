import Combine
import Darwin
import Foundation
import MeterBarShared

/// Persisted account opt-in. Provider is repeated intentionally so a UUID or
/// "default" identifier can never select an account under another provider.
nonisolated struct QuotaEventAccountSelection: Codable, Equatable, Hashable, Sendable {
    let provider: ServiceType
    let accountID: String

    init(provider: ServiceType, accountID: String) {
        self.provider = provider
        self.accountID = accountID
    }

    init(payload: QuotaEventPayload) {
        self.init(provider: payload.provider, accountID: payload.account.id)
    }

    /// Existing provider-wide Grok opt-ins used `default`. The default Grok
    /// profile now has a stable UUID, so rewrite that one identifier in place.
    var normalizedForPersistence: QuotaEventAccountSelection {
        guard provider == .grok, accountID == "default" else { return self }
        return QuotaEventAccountSelection(provider: .grok, accountID: GrokAccount.defaultID.uuidString)
    }

    func matches(_ payload: QuotaEventPayload) -> Bool {
        guard provider == payload.provider else { return false }
        if accountID == payload.account.id { return true }
        return provider == .grok
            && accountID == "default"
            && payload.account.id == GrokAccount.defaultID.uuidString
    }
}

/// Versioned app-wide outbound integration preferences.
///
/// Quota-event scopes are shared by local and webhook delivery so one explicit
/// event/provider/account selection has one meaning. Session Wake events are
/// local-only and retain their legacy event names and environment contract.
nonisolated struct QuotaEventIntegrationConfiguration: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var localDeliveryEnabled: Bool
    var localExecutablePath: String
    var localArguments: [String]
    var webhookDeliveryEnabled: Bool
    var webhookURLString: String
    var enabledQuotaEvents: Set<QuotaEventKind>
    var enabledProviders: Set<ServiceType>
    var enabledAccounts: Set<QuotaEventAccountSelection>
    var enabledWakeEvents: Set<WakeEventHookEvent>

    static let disabled = Self(
        version: currentVersion,
        localDeliveryEnabled: false,
        localExecutablePath: "",
        localArguments: [],
        webhookDeliveryEnabled: false,
        webhookURLString: "",
        enabledQuotaEvents: [],
        enabledProviders: [],
        enabledAccounts: [],
        enabledWakeEvents: []
    )

    var normalizedLocalExecutablePath: String {
        localExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var localIsConfigured: Bool {
        normalizedLocalExecutablePath.hasPrefix("/")
    }

    var validatedWebhookURL: URL? {
        QuotaWebhookURLPolicy.validatedURL(webhookURLString)
    }

    var wakeEventHookConfiguration: WakeEventHookConfiguration {
        guard localDeliveryEnabled, localIsConfigured else { return .disabled }
        return WakeEventHookConfiguration(
            executablePath: localExecutablePath,
            arguments: localArguments,
            enabledEvents: enabledWakeEvents
        )
    }

    func includes(_ payload: QuotaEventPayload) -> Bool {
        enabledQuotaEvents.contains(payload.event)
            && enabledProviders.contains(payload.provider)
            && enabledAccounts.contains { $0.matches(payload) }
    }

    func migratingLegacyGrokDefaultSelection() -> QuotaEventIntegrationConfiguration {
        var updated = self
        updated.enabledAccounts = Set(enabledAccounts.map(\.normalizedForPersistence))
        return updated
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case localDeliveryEnabled
        case localExecutablePath
        case localArguments
        case webhookDeliveryEnabled
        case webhookURLString
        case enabledQuotaEvents
        case enabledProviders
        case enabledAccounts
        case enabledWakeEvents
    }

    init(
        version: Int = currentVersion,
        localDeliveryEnabled: Bool,
        localExecutablePath: String,
        localArguments: [String],
        webhookDeliveryEnabled: Bool,
        webhookURLString: String,
        enabledQuotaEvents: Set<QuotaEventKind>,
        enabledProviders: Set<ServiceType>,
        enabledAccounts: Set<QuotaEventAccountSelection>,
        enabledWakeEvents: Set<WakeEventHookEvent>
    ) {
        self.version = version
        self.localDeliveryEnabled = localDeliveryEnabled
        self.localExecutablePath = localExecutablePath
        self.localArguments = localArguments
        self.webhookDeliveryEnabled = webhookDeliveryEnabled
        self.webhookURLString = webhookURLString
        self.enabledQuotaEvents = enabledQuotaEvents
        self.enabledProviders = enabledProviders
        self.enabledAccounts = enabledAccounts
        self.enabledWakeEvents = enabledWakeEvents
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        localDeliveryEnabled = try values.decodeIfPresent(Bool.self, forKey: .localDeliveryEnabled) ?? false
        localExecutablePath = try values.decodeIfPresent(String.self, forKey: .localExecutablePath) ?? ""
        localArguments = try values.decodeIfPresent([String].self, forKey: .localArguments) ?? []
        webhookDeliveryEnabled = try values.decodeIfPresent(Bool.self, forKey: .webhookDeliveryEnabled) ?? false
        webhookURLString = try values.decodeIfPresent(String.self, forKey: .webhookURLString) ?? ""
        enabledQuotaEvents = try values.decodeIfPresent(
            Set<QuotaEventKind>.self,
            forKey: .enabledQuotaEvents
        ) ?? []
        enabledProviders = try values.decodeIfPresent(Set<ServiceType>.self, forKey: .enabledProviders) ?? []
        enabledAccounts = try values.decodeIfPresent(
            Set<QuotaEventAccountSelection>.self,
            forKey: .enabledAccounts
        ) ?? []
        enabledWakeEvents = try values.decodeIfPresent(
            Set<WakeEventHookEvent>.self,
            forKey: .enabledWakeEvents
        ) ?? []
    }
}

/// Small injectable UserDefaults store matching the app's other preferences.
final class QuotaEventSettingsStore: ObservableObject {
    static let shared = QuotaEventSettingsStore()

    @Published private(set) var configuration: QuotaEventIntegrationConfiguration

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: StorageKeys.quotaEventIntegrations),
           let decoded = try? JSONDecoder().decode(QuotaEventIntegrationConfiguration.self, from: data) {
            let migrated = decoded.migratingLegacyGrokDefaultSelection()
            configuration = migrated
            if migrated != decoded {
                persist()
            }
        } else {
            configuration = Self.migratedConfiguration(from: userDefaults)
            persist()
        }
    }

    func setLocalExecutablePath(_ path: String) {
        guard path != configuration.localExecutablePath else { return }
        configuration.localExecutablePath = path
        if !configuration.localIsConfigured {
            configuration.localDeliveryEnabled = false
            configuration.enabledWakeEvents.removeAll()
        }
        persist()
    }

    func addLocalArgument() {
        configuration.localArguments.append("")
        persist()
    }

    func setLocalArgument(_ value: String, at index: Int) {
        guard configuration.localArguments.indices.contains(index),
              configuration.localArguments[index] != value else { return }
        configuration.localArguments[index] = value
        persist()
    }

    func removeLocalArgument(at index: Int) {
        guard configuration.localArguments.indices.contains(index) else { return }
        configuration.localArguments.remove(at: index)
        persist()
    }

    func setLocalDeliveryEnabled(_ enabled: Bool) {
        if enabled, !configuration.localIsConfigured { return }
        guard enabled != configuration.localDeliveryEnabled else { return }
        configuration.localDeliveryEnabled = enabled
        persist()
    }

    func setWebhookURLString(_ value: String) {
        guard value != configuration.webhookURLString else { return }
        configuration.webhookURLString = value
        if configuration.validatedWebhookURL == nil {
            configuration.webhookDeliveryEnabled = false
        }
        persist()
    }

    func setWebhookDeliveryEnabled(_ enabled: Bool) {
        if enabled, configuration.validatedWebhookURL == nil { return }
        guard enabled != configuration.webhookDeliveryEnabled else { return }
        configuration.webhookDeliveryEnabled = enabled
        persist()
    }

    func setQuotaEventEnabled(_ enabled: Bool, for event: QuotaEventKind) {
        guard let updated = updatedSet(configuration.enabledQuotaEvents, value: event, enabled: enabled) else {
            return
        }
        configuration.enabledQuotaEvents = updated
        persist()
    }

    func setProviderEnabled(_ enabled: Bool, for provider: ServiceType) {
        guard let updated = updatedSet(configuration.enabledProviders, value: provider, enabled: enabled) else {
            return
        }
        configuration.enabledProviders = updated
        persist()
    }

    func setAccountEnabled(_ enabled: Bool, for account: QuotaEventAccountSelection) {
        let normalized = account.normalizedForPersistence
        let current = Set(configuration.enabledAccounts.map(\.normalizedForPersistence))
        guard let updated = updatedSet(current, value: normalized, enabled: enabled) else {
            return
        }
        configuration.enabledAccounts = updated
        persist()
    }

    func setWakeEventEnabled(_ enabled: Bool, for event: WakeEventHookEvent) {
        if enabled, !configuration.localIsConfigured { return }
        guard let updated = updatedSet(configuration.enabledWakeEvents, value: event, enabled: enabled) else {
            return
        }
        configuration.enabledWakeEvents = updated
        persist()
    }

    private func updatedSet<Value: Hashable>(
        _ current: Set<Value>,
        value: Value,
        enabled: Bool
    ) -> Set<Value>? {
        var updated = current
        let changed: Bool
        if enabled {
            changed = updated.insert(value).inserted
        } else {
            changed = updated.remove(value) != nil
        }
        return changed ? updated : nil
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        userDefaults.set(data, forKey: StorageKeys.quotaEventIntegrations)

        // Keep the old key as a compatibility mirror for an older app binary
        // and for the managed Session Wake agent's existing durable contract.
        if let legacy = try? JSONEncoder().encode(configuration.wakeEventHookConfiguration) {
            userDefaults.set(legacy, forKey: StorageKeys.sessionWakeEventHooks)
        }
    }

    private static func migratedConfiguration(
        from userDefaults: UserDefaults
    ) -> QuotaEventIntegrationConfiguration {
        guard let data = userDefaults.data(forKey: StorageKeys.sessionWakeEventHooks),
              let legacy = try? JSONDecoder().decode(WakeEventHookConfiguration.self, from: data) else {
            return .disabled
        }
        return QuotaEventIntegrationConfiguration(
            localDeliveryEnabled: legacy.isConfigured && !legacy.enabledEvents.isEmpty,
            localExecutablePath: legacy.executablePath,
            localArguments: legacy.arguments,
            webhookDeliveryEnabled: false,
            webhookURLString: "",
            enabledQuotaEvents: [],
            enabledProviders: [],
            enabledAccounts: [],
            enabledWakeEvents: legacy.enabledEvents
        )
    }
}

/// Conservative outbound URL boundary for an explicitly configured desktop
/// webhook. Delivery adds a no-redirect policy; this gate rejects schemes that
/// can read local files and obvious loopback/private-service targets.
nonisolated enum QuotaWebhookURLPolicy {
    static func validatedURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 2_048,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(),
              !host.isEmpty,
              !isUnsafeHost(host),
              let url = components.url else {
            return nil
        }
        return url
    }

    /// Resolve immediately before delivery and reject the endpoint if any
    /// address is loopback, link-local, private, multicast, or otherwise
    /// non-public. This closes the obvious DNS-to-private SSRF route in
    /// addition to the literal-host checks above.
    static func hostResolvesOnlyToPublicAddresses(_ host: String) -> Bool {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &result) == 0, let result else {
            return false
        }
        defer { freeaddrinfo(result) }

        var sawAddress = false
        var current: UnsafeMutablePointer<addrinfo>? = result
        while let info = current?.pointee {
            defer { current = info.ai_next }
            guard let address = info.ai_addr else { continue }
            switch Int32(info.ai_family) {
            case AF_INET:
                sawAddress = true
                let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
                if isUnsafeIPv4(UInt32(bigEndian: ipv4.s_addr)) {
                    return false
                }
            case AF_INET6:
                sawAddress = true
                var ipv6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_addr
                }
                if isUnsafeIPv6(&ipv6) {
                    return false
                }
            default:
                break
            }
        }
        return sawAddress
    }

    /// Whether a transaction metric's remote-address literal belongs to an
    /// address range the webhook policy forbids. Foundation may include IPv6
    /// brackets, an interface zone, or a transport port, so normalize those
    /// presentation details before asking `inet_pton` to parse the address.
    /// Unknown formats fail open, matching delivery's deliberate behavior when
    /// URLSession reports no remote address at all.
    static func isUnsafeAddressLiteral(_ value: String) -> Bool {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }

        if candidate.hasPrefix("["), let closingBracket = candidate.firstIndex(of: "]") {
            candidate = String(candidate[candidate.index(after: candidate.startIndex)..<closingBracket])
        }

        if let zone = candidate.firstIndex(of: "%") {
            candidate = String(candidate[..<zone])
        }

        if let result = unsafeAddressParseResult(candidate) {
            return result
        }

        // An unbracketed IPv4 address may carry `:port`. Try the complete
        // literal first above so a valid IPv6 address ending in digits is never
        // mistaken for a host-plus-port pair.
        if let colon = candidate.lastIndex(of: ":") {
            let port = candidate[candidate.index(after: colon)...]
            let host = String(candidate[..<colon])
            if !port.isEmpty, port.allSatisfy(\.isNumber), let result = unsafeAddressParseResult(host) {
                return result
            }
        }

        return false
    }

    private static func unsafeAddressParseResult(_ value: String) -> Bool? {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            return isUnsafeIPv4(UInt32(bigEndian: ipv4.s_addr))
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, value, &ipv6) == 1 {
            return isUnsafeIPv6(&ipv6)
        }
        return nil
    }

    private static func isUnsafeHost(_ host: String) -> Bool {
        if host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host.hasSuffix(".internal") {
            return true
        }

        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            return isUnsafeIPv4(UInt32(bigEndian: ipv4.s_addr))
        }
        // Reject alternative numeric IPv4 spellings (integer, octal, or
        // shortened dotted forms) rather than letting URLSession reinterpret.
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            return true
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            return isUnsafeIPv6(&ipv6)
        }

        // Webhook hosts should be public DNS names, not single-label LAN names.
        return !host.contains(".")
    }

    private static func isUnsafeIPv6(_ address: inout in6_addr) -> Bool {
        withUnsafeBytes(of: &address) { rawBuffer in
            let bytes = Array(rawBuffer)
            guard bytes.count == 16 else { return true }
            if bytes.allSatisfy({ $0 == 0 }) { return true } // unspecified
            if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return true } // loopback
            if bytes[0] & 0xFE == 0xFC { return true } // unique-local fc00::/7
            if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true } // link-local fe80::/10
            if bytes[0] == 0xFF { return true } // multicast
            if bytes[0..<10].allSatisfy({ $0 == 0 }),
               bytes[10] == 0xFF,
               bytes[11] == 0xFF {
                let mapped = bytes[12...15].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                return isUnsafeIPv4(mapped)
            }
            return false
        }
    }

    private static func isUnsafeIPv4(_ address: UInt32) -> Bool {
        let first = address >> 24
        let second = (address >> 16) & 0xFF
        return first == 0
            || first == 10
            || first == 127
            || (first == 100 && (64...127).contains(second))
            || (first == 169 && second == 254)
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
            || (first == 198 && (second == 18 || second == 19))
            || first >= 224
    }
}
