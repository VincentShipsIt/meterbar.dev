import Foundation

// MARK: - RoutingPolicyDocument

/// The persisted set of routing policies: only what the user changed or added.
///
/// A built-in task with no entry here uses its shipped default, so a default
/// that improves in a later release reaches everyone who never customised it.
/// Storing a full copy of every default would freeze them.
public struct RoutingPolicyDocument: Equatable, Sendable {
    public static let empty = RoutingPolicyDocument(policies: [])

    public private(set) var policies: [RoutingPolicy]

    public init(policies: [RoutingPolicy]) {
        var seen = Set<RoutingTaskID>()
        self.policies = policies
            .map { $0.sanitized() }
            .filter { seen.insert($0.task).inserted }
            .sorted { $0.task < $1.task }
    }

    public func policy(for task: RoutingTaskID) -> RoutingPolicy? {
        policies.first { $0.task == task }
    }

    /// The document with `policy` stored. A built-in policy identical to its
    /// shipped default is dropped instead, so "reset to default" and "edited
    /// back to default" are the same state on disk.
    public func setting(_ policy: RoutingPolicy) -> RoutingPolicyDocument {
        let clean = policy.sanitized()
        let others = policies.filter { $0.task != clean.task }
        if clean.task.isBuiltIn, clean == RoutingPolicyDefaults.policy(for: clean.task) {
            return RoutingPolicyDocument(policies: others)
        }
        return RoutingPolicyDocument(policies: others + [clean])
    }

    /// The document with `task`'s stored policy removed: a built-in returns to
    /// its default, a custom task is deleted.
    public func resetting(_ task: RoutingTaskID) -> RoutingPolicyDocument {
        RoutingPolicyDocument(policies: policies.filter { $0.task != task })
    }
}

// MARK: - RoutingPolicyMigration

/// One explicit step from schema version `from` to `from + 1`, applied to the
/// raw JSON object so it can rename or reshape fields the current types no
/// longer describe.
public struct RoutingPolicyMigration: @unchecked Sendable {
    public let from: Int
    public let migrate: ([String: Any]) -> [String: Any]

    public init(from: Int, migrate: @escaping ([String: Any]) -> [String: Any]) {
        self.from = from
        self.migrate = migrate
    }
}

// MARK: - RoutingPolicyDocumentCodec

/// Reads and writes the versioned policy file.
///
/// The contract for schema change is explicit rather than tolerant-by-luck:
///
/// - a document at an older version is walked forward one registered
///   `RoutingPolicyMigration` at a time and reported as migrated, so the caller
///   can persist the upgraded form;
/// - a document at a **newer** version is never interpreted and never
///   overwritten — a future build may understand fields this one dropped, so
///   this build must leave its bytes alone;
/// - a document that is not JSON, has no version, or needs a migration that is
///   not registered is unreadable.
///
/// Within one version, decoding is field-tolerant (`RoutingPolicy.init(from:)`),
/// so an unknown enum case degrades one field rather than the file.
public struct RoutingPolicyDocumentCodec: Sendable {
    public static let currentSchemaVersion = 1
    public static let standard = RoutingPolicyDocumentCodec()

    public enum Loaded: Equatable, Sendable {
        /// `migratedFrom` is the on-disk version when it was older than current.
        case document(RoutingPolicyDocument, migratedFrom: Int?)
        case unsupportedVersion(Int)
        case unreadable
    }

    public let currentVersion: Int
    private let migrations: [RoutingPolicyMigration]

    public init(
        currentVersion: Int = RoutingPolicyDocumentCodec.currentSchemaVersion,
        migrations: [RoutingPolicyMigration] = []
    ) {
        self.currentVersion = currentVersion
        self.migrations = migrations
    }

    public func encode(_ document: RoutingPolicyDocument) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(Envelope(schemaVersion: currentVersion, policies: document.policies))
    }

    public func decode(_ data: Data) -> Loaded {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var version = object["schemaVersion"] as? Int,
              version >= 1 else {
            return .unreadable
        }
        guard version <= currentVersion else {
            return .unsupportedVersion(version)
        }

        let diskVersion = version
        while version < currentVersion {
            guard let step = migrations.first(where: { $0.from == version }) else {
                return .unreadable
            }
            object = step.migrate(object)
            version += 1
            object["schemaVersion"] = version
        }

        guard let migrated = try? JSONSerialization.data(withJSONObject: object),
              let payload = try? JSONDecoder().decode(Payload.self, from: migrated) else {
            return .unreadable
        }
        return .document(
            RoutingPolicyDocument(policies: payload.policies.compactMap(\.value)),
            migratedFrom: diskVersion < currentVersion ? diskVersion : nil
        )
    }

    private struct Envelope: Encodable {
        let schemaVersion: Int
        let policies: [RoutingPolicy]
    }

    /// Policies decode through `FailableBox`, so one unreadable entry drops
    /// itself without taking the user's other policies with it.
    private struct Payload: Decodable {
        let policies: [FailableBox<RoutingPolicy>]
    }
}

// MARK: - RoutingPolicyCatalog

/// The policies in force: shipped defaults overlaid with what the user stored.
public struct RoutingPolicyCatalog: Equatable, Sendable {
    public let document: RoutingPolicyDocument

    public init(document: RoutingPolicyDocument = .empty) {
        self.document = document
    }

    /// Every built-in task (stored override or default) in documented order,
    /// then the user's custom tasks alphabetically.
    public var policies: [RoutingPolicy] {
        let builtIns = RoutingTaskID.builtIn.map { policy(for: $0) ?? RoutingPolicyDefaults.policy(for: $0) }
        let customs = document.policies.filter { !$0.task.isBuiltIn }
        return builtIns + customs
    }

    /// The effective policy for `task`. Always present for a built-in; `nil`
    /// for a custom id the user has not defined.
    public func policy(for task: RoutingTaskID) -> RoutingPolicy? {
        if let stored = document.policy(for: task) {
            return stored
        }
        return task.isBuiltIn ? RoutingPolicyDefaults.policy(for: task) : nil
    }

    public func isCustomized(_ task: RoutingTaskID) -> Bool {
        document.policy(for: task) != nil
    }

    /// Ids a caller may pass as `--task`, in listing order.
    public var taskIDs: [RoutingTaskID] {
        policies.map(\.task)
    }
}
