import Foundation

/// A provider account a policy can name. The provider is repeated on purpose
/// so an id can never select an account under a different provider.
public struct RoutingAccountRef: Hashable, Codable, Sendable {
    public let provider: ServiceType
    public let accountID: UUID

    public init(provider: ServiceType, accountID: UUID) {
        self.provider = provider
        self.accountID = accountID
    }
}

/// Provider-neutral model tiers. A policy names a tier, and may map a provider
/// to a concrete alias of the user's choosing; MeterBar ships no model ids of
/// its own because they go stale faster than the app releases.
public enum RoutingModelTier: String, Codable, CaseIterable, Sendable {
    case economy
    case standard
    case premium
}

/// How strongly a route should avoid metered (pay-per-use) spend.
public enum RoutingCostPreference: String, Codable, CaseIterable, Sendable {
    /// Rank on quota headroom alone.
    case headroom
    case balanced
    /// Strongly prefer included subscription quota over metered spend.
    case cost
}

/// How the fallback chain behind the recommendation is ordered.
public enum RoutingFallbackOrder: String, Codable, CaseIterable, Sendable {
    /// By the same score that picked the recommendation.
    case score
    /// By the policy's provider preference first, then by score.
    case policyPreference
}

/// Whether the provider preference list only ranks, or also restricts.
public enum RoutingProviderScope: String, Codable, CaseIterable, Sendable {
    /// Any provider may be recommended; preferred ones score higher.
    case anyProvider
    /// Only providers in the preference list are eligible.
    case preferredOnly
}

/// How the policy treats accounts of a provider it lists in `accounts`.
public enum RoutingAccountSelection: String, Codable, CaseIterable, Sendable {
    /// Every account competes on headroom alone.
    case automatic
    /// Listed accounts score higher; others stay eligible.
    case preferred
    /// A provider with listed accounts is restricted to exactly those.
    case restricted
}

/// Everything the router needs to know about one kind of work.
///
/// A policy is data, not code: it is persisted, edited in the dashboard in a
/// later phase, and read by the CLI. Construct it through
/// `RoutingPolicyDefaults` or decode it; both paths end in `sanitized()`, so a
/// policy in memory always satisfies the documented ranges.
public struct RoutingPolicy: Equatable, Sendable {
    public static let maximumFallbackCount = 4
    public static let maximumNameLength = 40
    public static let maximumAliasLength = 64

    public var task: RoutingTaskID
    /// Display name. Built-ins carry theirs; a custom task's is the user's.
    public var name: String
    /// Providers in the order the user prefers them.
    public var providerPreference: [ServiceType]
    public var providerScope: RoutingProviderScope
    public var accountSelection: RoutingAccountSelection
    public var accounts: [RoutingAccountRef]
    public var modelTier: RoutingModelTier
    /// Optional concrete model name per provider, shown in the decision.
    public var modelAliases: [ServiceType: String]
    /// A candidate with less than this percent of quota left is rejected.
    public var minimumRemainingPercent: Int
    /// A candidate burning more than this many points ahead of sustainable
    /// pace is rejected. `nil` sets no limit. Unknown pace never rejects.
    public var maximumDeficitPercent: Int?
    /// Whether a quota whose total MeterBar estimated may be recommended.
    public var allowsEstimatedQuota: Bool
    public var costPreference: RoutingCostPreference
    public var fallbackOrder: RoutingFallbackOrder
    public var maximumFallbacks: Int

    public init(
        task: RoutingTaskID,
        name: String,
        providerPreference: [ServiceType] = [],
        providerScope: RoutingProviderScope = .anyProvider,
        accountSelection: RoutingAccountSelection = .automatic,
        accounts: [RoutingAccountRef] = [],
        modelTier: RoutingModelTier = .standard,
        modelAliases: [ServiceType: String] = [:],
        minimumRemainingPercent: Int = 10,
        maximumDeficitPercent: Int? = nil,
        allowsEstimatedQuota: Bool = false,
        costPreference: RoutingCostPreference = .balanced,
        fallbackOrder: RoutingFallbackOrder = .score,
        maximumFallbacks: Int = 2
    ) {
        self.task = task
        self.name = name
        self.providerPreference = providerPreference
        self.providerScope = providerScope
        self.accountSelection = accountSelection
        self.accounts = accounts
        self.modelTier = modelTier
        self.modelAliases = modelAliases
        self.minimumRemainingPercent = minimumRemainingPercent
        self.maximumDeficitPercent = maximumDeficitPercent
        self.allowsEstimatedQuota = allowsEstimatedQuota
        self.costPreference = costPreference
        self.fallbackOrder = fallbackOrder
        self.maximumFallbacks = maximumFallbacks
        self = sanitized()
    }

    /// The same policy forced into its documented ranges: percentages clamped
    /// to 0...100, the fallback count to 0...4, duplicates dropped keeping the
    /// first occurrence, and every free-text field passed through
    /// `RoutingLabel` so nothing unsafe can reach routing output.
    public func sanitized() -> RoutingPolicy {
        var policy = self
        let fallbackName = task.builtInName ?? task.rawValue
        policy.name = String(
            RoutingLabel.sanitized(name, fallback: fallbackName).prefix(Self.maximumNameLength)
        )
        policy.providerPreference = Self.uniqued(providerPreference)
        policy.accounts = Self.uniqued(accounts)
        policy.minimumRemainingPercent = min(100, max(0, minimumRemainingPercent))
        policy.maximumDeficitPercent = maximumDeficitPercent.map { min(100, max(0, $0)) }
        policy.maximumFallbacks = min(Self.maximumFallbackCount, max(0, maximumFallbacks))
        policy.modelAliases = modelAliases.filter { Self.isValidAlias($0.value) }
        return policy
    }

    /// Alias grammar: letters, digits, and `. _ : -`, up to 64 characters. No
    /// separators, so an alias cannot smuggle in a path or an address.
    public static func isValidAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty, alias.count <= maximumAliasLength else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        return alias.allSatisfy { allowed.contains($0) }
    }

    /// Position of `service` in the preference list, or `nil` when unlisted.
    public func preferenceRank(of service: ServiceType) -> Int? {
        providerPreference.firstIndex(of: service)
    }

    private static func uniqued<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}

// MARK: - Codable

extension RoutingPolicy: Codable {
    private enum CodingKeys: String, CodingKey {
        case task
        case name
        case providerPreference
        case providerScope
        case accountSelection
        case accounts
        case modelTier
        case modelAliases
        case minimumRemainingPercent
        case maximumDeficitPercent
        case allowsEstimatedQuota
        case costPreference
        case fallbackOrder
        case maximumFallbacks
    }

    /// Decodes field by field over the task's own defaults, so a field this
    /// build cannot read — a renamed enum case, a provider it has never heard
    /// of — degrades alone instead of discarding the whole policy. Only the
    /// task id is required: without it nothing says what the policy is for.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let task = try values.decode(RoutingTaskID.self, forKey: .task)
        let base = RoutingPolicyDefaults.policy(for: task)

        self.task = task
        name = Self.tolerant(String.self, values, .name) ?? base.name
        providerPreference = Self.tolerant([FailableBox<ServiceType>].self, values, .providerPreference)
            .map { $0.compactMap(\.value) } ?? base.providerPreference
        providerScope = Self.tolerant(RoutingProviderScope.self, values, .providerScope) ?? base.providerScope
        accountSelection = Self.tolerant(RoutingAccountSelection.self, values, .accountSelection)
            ?? base.accountSelection
        accounts = Self.tolerant([FailableBox<RoutingAccountRef>].self, values, .accounts)
            .map { $0.compactMap(\.value) } ?? base.accounts
        modelTier = Self.tolerant(RoutingModelTier.self, values, .modelTier) ?? base.modelTier
        modelAliases = Self.tolerant([String: String].self, values, .modelAliases)
            .map { raw in
                Dictionary(uniqueKeysWithValues: raw.compactMap { key, alias in
                    ServiceType(rawValue: key).map { ($0, alias) }
                })
            } ?? base.modelAliases
        minimumRemainingPercent = Self.tolerant(Int.self, values, .minimumRemainingPercent)
            ?? base.minimumRemainingPercent
        if values.contains(.maximumDeficitPercent),
           (try? values.decodeNil(forKey: .maximumDeficitPercent)) == true {
            maximumDeficitPercent = nil
        } else {
            maximumDeficitPercent = Self.tolerant(Int.self, values, .maximumDeficitPercent)
                ?? base.maximumDeficitPercent
        }
        allowsEstimatedQuota = Self.tolerant(Bool.self, values, .allowsEstimatedQuota)
            ?? base.allowsEstimatedQuota
        costPreference = Self.tolerant(RoutingCostPreference.self, values, .costPreference)
            ?? base.costPreference
        fallbackOrder = Self.tolerant(RoutingFallbackOrder.self, values, .fallbackOrder) ?? base.fallbackOrder
        maximumFallbacks = Self.tolerant(Int.self, values, .maximumFallbacks) ?? base.maximumFallbacks
        self = sanitized()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(task, forKey: .task)
        try container.encode(name, forKey: .name)
        try container.encode(providerPreference, forKey: .providerPreference)
        try container.encode(providerScope, forKey: .providerScope)
        try container.encode(accountSelection, forKey: .accountSelection)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(modelTier, forKey: .modelTier)
        try container.encode(
            Dictionary(uniqueKeysWithValues: modelAliases.map { ($0.key.rawValue, $0.value) }),
            forKey: .modelAliases
        )
        try container.encode(minimumRemainingPercent, forKey: .minimumRemainingPercent)
        // An explicit null, not an omitted key: on decode a missing key means
        // "use the default", so omitting it would silently turn a user's
        // deliberate "no deficit limit" back into the task's default cap.
        if let maximumDeficitPercent {
            try container.encode(maximumDeficitPercent, forKey: .maximumDeficitPercent)
        } else {
            try container.encodeNil(forKey: .maximumDeficitPercent)
        }
        try container.encode(allowsEstimatedQuota, forKey: .allowsEstimatedQuota)
        try container.encode(costPreference, forKey: .costPreference)
        try container.encode(fallbackOrder, forKey: .fallbackOrder)
        try container.encode(maximumFallbacks, forKey: .maximumFallbacks)
    }

    private static func tolerant<T: Decodable>(
        _ type: T.Type,
        _ values: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> T? {
        try? values.decodeIfPresent(type, forKey: key)
    }
}
