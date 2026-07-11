import Combine
import Foundation

/// Pure mapping from watcher state to the user-facing status surface.
///
/// Real states are surfaced distinctly (Running / Stopping / Quota Unknown /
/// Needs Attention) rather than collapsed into "Watching", so the UI and CLI
/// can always explain why nothing is launching.
enum SessionWakeStatusLabel: Equatable {
    case off
    case idle
    case scanning
    case waiting
    case quotaUnknown
    case running
    case stopping
    case completed
    case needsAttention

    /// The short chip title.
    var title: String {
        switch self {
        case .off: return "Off"
        case .idle: return "Idle"
        case .scanning: return "Scanning"
        case .waiting: return "Waiting"
        case .quotaUnknown: return "Quota Unknown"
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .completed: return "Completed"
        case .needsAttention: return "Needs Attention"
        }
    }

    /// Whether this label represents a failure the user should look at.
    var isAttention: Bool { self == .needsAttention || self == .quotaUnknown }

    /// Derive the label from the watcher state and whether the toggle is on.
    static func from(state: WakeWatcherState, isOn: Bool) -> SessionWakeStatusLabel {
        guard isOn else { return .off }
        switch state {
        case .off: return .idle
        case .idle: return .idle
        case .scanning: return .scanning
        case .waiting: return .waiting
        case .quotaUnknown: return .quotaUnknown
        case .running: return .running
        case .stopping: return .stopping
        case .completed: return .completed
        case .failed: return .needsAttention
        }
    }
}

/// Shared observable status surface consumed by both the Settings pane and the
/// menu-bar control, so the two controls always reflect one source of truth.
@MainActor
final class SessionWakeStatus: ObservableObject {
    static let shared = SessionWakeStatus()

    @Published private(set) var watcherState: WakeWatcherState = .off
    @Published private(set) var previewCandidates: [WakeSessionCandidate] = []
    @Published private(set) var isPreviewing = false
    @Published private(set) var lastSummary: WakeRunSummary?

    private let discovery: SessionDiscovery
    private let ledgerFactory: @Sendable () -> ReplayLedger

    init(
        discovery: SessionDiscovery = SessionDiscovery(),
        ledgerFactory: @escaping @Sendable () -> ReplayLedger = { ReplayLedger() }
    ) {
        self.discovery = discovery
        self.ledgerFactory = ledgerFactory
    }

    /// Number of executable (resumable) candidates in the last preview.
    var eligibleCount: Int { previewCandidates.filter(\.isExecutable).count }

    /// Skip reasons and their counts, for explaining non-resumed sessions.
    var skipSummary: [WakeSkipReason: Int] {
        Dictionary(grouping: previewCandidates.compactMap(\.skipReason), by: { $0 })
            .mapValues(\.count)
    }

    /// Read-only preview of resumable sessions. Explicitly permitted even while
    /// the feature/watcher are off — it performs no subprocess or mutation.
    func preview(configDirectory: String?) async {
        isPreviewing = true
        defer { isPreviewing = false }
        let ledger = ledgerFactory()
        previewCandidates = await discovery.discover(configDirectory: configDirectory, ledger: ledger)
    }

    /// Mirror a new coordinator state into the published surface.
    func update(state: WakeWatcherState) {
        watcherState = state
        if case let .completed(summary) = state {
            lastSummary = summary
        }
    }

    func label(isOn: Bool) -> SessionWakeStatusLabel {
        SessionWakeStatusLabel.from(state: watcherState, isOn: isOn)
    }
}
