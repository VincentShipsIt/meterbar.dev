import Foundation
import MeterBarShared

/// The draft behind the Routing page's policy editor.
///
/// Edits stay in memory until `save`. The editor covers the built-in tasks
/// only; a custom task already in the file is carried through every save
/// untouched, so editing the shipped tasks can never delete it.
///
/// Persistence goes through `RoutingPolicyStore.save`, which refuses to
/// overwrite a file from a newer MeterBar or one it cannot read. The editor
/// adds the other half of that promise: it will not write a policy that could
/// never produce a route, and it never silently drops what the user typed.
nonisolated struct RoutingPolicyEditor: Equatable {
    struct Problem: Equatable {
        let task: RoutingTaskID
        let message: String
    }

    enum SaveError: Error, Equatable {
        /// The draft has a problem; nothing was written.
        case blocked(String)
        /// The store refused or failed; the draft is kept so nothing is lost.
        case storage(String)
    }

    /// An account a policy can name, labelled the way routing output labels it.
    struct AccountOption: Equatable, Identifiable {
        let ref: RoutingAccountRef
        let label: String

        var id: RoutingAccountRef { ref }
    }

    private var baseline: RoutingPolicyDocument
    private(set) var drafts: [RoutingPolicy]

    init(catalog: RoutingPolicyCatalog) {
        baseline = catalog.document
        drafts = RoutingTaskID.builtIn.compactMap { catalog.policy(for: $0) }
    }

    // MARK: State

    func draft(_ task: RoutingTaskID) -> RoutingPolicy? {
        drafts.first { $0.task == task }
    }

    var isDirty: Bool {
        drafts != Self.savedDrafts(of: baseline)
    }

    /// Whether the draft for `task` differs from the shipped default.
    func isCustomized(_ task: RoutingTaskID) -> Bool {
        draft(task) != Self.defaultPolicy(for: task)
    }

    var problems: [Problem] {
        drafts.flatMap(Self.problems(in:))
    }

    /// Why Save is unavailable, or `nil` when the draft can be saved.
    var saveBlockedReason: String? {
        problems.first?.message
    }

    // MARK: Editing

    /// Applies `change` to the draft for `task`. Numbers are clamped and lists
    /// de-duplicated, but a model alias is kept as typed so an invalid one is
    /// reported rather than dropped.
    mutating func edit(_ task: RoutingTaskID, _ change: (inout RoutingPolicy) -> Void) {
        guard let index = drafts.firstIndex(where: { $0.task == task }) else {
            return
        }
        var policy = drafts[index]
        change(&policy)
        let aliases = policy.modelAliases
        policy = policy.sanitized()
        policy.modelAliases = aliases
        drafts[index] = policy
    }

    mutating func setAlias(_ alias: String, for provider: ServiceType, in task: RoutingTaskID) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        edit(task) { policy in
            if trimmed.isEmpty {
                policy.modelAliases[provider] = nil
            } else {
                policy.modelAliases[provider] = trimmed
            }
        }
    }

    mutating func setPreferred(_ provider: ServiceType, included: Bool, in task: RoutingTaskID) {
        edit(task) { policy in
            policy.providerPreference.removeAll { $0 == provider }
            if included {
                policy.providerPreference.append(provider)
            }
        }
    }

    /// Moves `provider` one place earlier (`up`) or later in the preference
    /// order; at either end it stays put.
    mutating func moveProvider(_ provider: ServiceType, up: Bool, in task: RoutingTaskID) {
        edit(task) { policy in
            guard let index = policy.providerPreference.firstIndex(of: provider) else {
                return
            }
            let target = up ? index - 1 : index + 1
            guard policy.providerPreference.indices.contains(target) else {
                return
            }
            policy.providerPreference.swapAt(index, target)
        }
    }

    mutating func setAccount(_ account: RoutingAccountRef, included: Bool, in task: RoutingTaskID) {
        edit(task) { policy in
            policy.accounts.removeAll { $0 == account }
            if included {
                policy.accounts.append(account)
            }
        }
    }

    // MARK: Reset and cancel

    /// Puts one task's draft back to its shipped default. Nothing is written
    /// until `save`.
    mutating func reset(_ task: RoutingTaskID) {
        guard let index = drafts.firstIndex(where: { $0.task == task }) else {
            return
        }
        drafts[index] = Self.defaultPolicy(for: task)
    }

    mutating func resetAll() {
        drafts = RoutingTaskID.builtIn.map(Self.defaultPolicy(for:))
    }

    mutating func cancel() {
        drafts = Self.savedDrafts(of: baseline)
    }

    // MARK: Saving

    /// What would be written: the stored document with each built-in draft
    /// applied. A draft equal to its default is removed, and anything the
    /// editor does not show (custom tasks) is left exactly as it was.
    var resultingDocument: RoutingPolicyDocument {
        drafts.reduce(baseline) { document, draft in
            document.setting(draft)
        }
    }

    mutating func save(
        directory: URL? = SharedMetricsStore.containerURL,
        writer: RoutingPolicyStore.Writer = { try SecureFileWriter.write($0, to: $1) }
    ) throws {
        if let reason = saveBlockedReason {
            throw SaveError.blocked(reason)
        }
        let document = resultingDocument
        do {
            try RoutingPolicyStore.save(document, directory: directory, writer: writer)
        } catch {
            throw SaveError.storage(error.localizedDescription)
        }
        baseline = document
        drafts = Self.savedDrafts(of: document)
    }

    // MARK: Accounts

    /// Accounts of routable providers, in the order the candidates list them.
    static func accountOptions(from candidates: [RoutingCandidate]) -> [AccountOption] {
        var seen = Set<RoutingAccountRef>()
        return candidates.compactMap { candidate in
            guard candidate.service.supportsWorkloadRouting, let accountID = candidate.accountID else {
                return nil
            }
            let ref = RoutingAccountRef(provider: candidate.service, accountID: accountID)
            guard seen.insert(ref).inserted else {
                return nil
            }
            return AccountOption(
                ref: ref,
                label: RoutingLabel.sanitized(
                    candidate.accountName,
                    fallback: RoutingLabel.fallbackAccountLabel(id: accountID)
                )
            )
        }
    }

    /// Retain saved references in the editor even after an account disappears.
    static func accountOptions(available: [AccountOption], saved: [RoutingAccountRef]) -> [AccountOption] {
        var options = available
        var seen = Set(available.map(\.ref))
        for ref in saved where seen.insert(ref).inserted {
            options.append(AccountOption(
                ref: ref,
                label: "\(RoutingLabel.fallbackAccountLabel(id: ref.accountID)) (unavailable)"
            ))
        }
        return options
    }

    // MARK: Private

    private static func defaultPolicy(for task: RoutingTaskID) -> RoutingPolicy {
        RoutingPolicyDefaults.policy(for: task)
    }

    private static func savedDrafts(of document: RoutingPolicyDocument) -> [RoutingPolicy] {
        RoutingPolicyCatalog(document: document).policies.filter { $0.task.isBuiltIn }
    }

    private static func problems(in policy: RoutingPolicy) -> [Problem] {
        var found: [Problem] = []
        if policy.providerScope == .preferredOnly {
            let routable = policy.providerPreference.filter(\.supportsWorkloadRouting)
            if policy.providerPreference.isEmpty {
                found.append(Problem(
                    task: policy.task,
                    message: "\(policy.name) is limited to preferred providers, but none are chosen. "
                        + "Pick a provider or allow any."
                ))
            } else if routable.isEmpty {
                found.append(Problem(
                    task: policy.task,
                    message: "\(policy.name) is limited to preferred providers, but none of them can be routed. "
                        + "Pick another provider or allow any."
                ))
            }
        }
        for (provider, alias) in policy.modelAliases.sorted(by: { $0.key.rawValue < $1.key.rawValue })
            where !RoutingPolicy.isValidAlias(alias) {
            found.append(Problem(
                task: policy.task,
                message: "\(policy.name): the model name for \(provider.displayName) "
                    + "may only use letters, numbers and . _ : -"
            ))
        }
        return found
    }
}
