import Combine
import MeterBarShared
import Foundation

final class ProviderVisibilityStore: ObservableObject {
    static let shared = ProviderVisibilityStore()

    @Published private(set) var hiddenServices: Set<ServiceType> = []

    private let userDefaults: UserDefaults
    private let storageKey = StorageKeys.hiddenProviderServices

    var enabledServices: Set<ServiceType> {
        Set(ServiceType.allCases).subtracting(hiddenServices)
    }

    private init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        load()
    }

    func isEnabled(_ service: ServiceType) -> Bool {
        !hiddenServices.contains(service)
    }

    func set(_ service: ServiceType, isEnabled enabled: Bool) {
        var nextHiddenServices = hiddenServices

        if enabled {
            nextHiddenServices.remove(service)
        } else {
            nextHiddenServices.insert(service)
        }

        guard nextHiddenServices != hiddenServices else { return }
        hiddenServices = nextHiddenServices
        save()
    }

    private func load() {
        let rawValues = userDefaults.stringArray(forKey: storageKey) ?? []
        hiddenServices = Set(rawValues.compactMap(ServiceType.init(rawValue:)))
    }

    private func save() {
        let rawValues = hiddenServices.map(\.rawValue).sorted()
        userDefaults.set(rawValues, forKey: storageKey)
    }
}
