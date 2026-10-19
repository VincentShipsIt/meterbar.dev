import Combine
import Foundation
import MeterBarShared

/// Which task the popover's one-line routing recommendation is for. Changeable
/// from the Routing page; Implementation until the user picks another.
final class PopoverRoutingSettingsStore: ObservableObject {
    static let shared = PopoverRoutingSettingsStore()
    static let defaultTask = RoutingTaskID.implementation

    @Published private(set) var task: RoutingTaskID

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        task = userDefaults.string(forKey: StorageKeys.popoverRoutingTask)
            .flatMap { RoutingTaskID(token: $0) } ?? Self.defaultTask
    }

    func setTask(_ task: RoutingTaskID) {
        guard task != self.task else { return }
        self.task = task
        userDefaults.set(task.rawValue, forKey: StorageKeys.popoverRoutingTask)
    }
}
