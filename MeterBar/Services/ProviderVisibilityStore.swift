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

    /// Internal (not private) so tests can construct an instance backed by an
    /// isolated `UserDefaults` suite; production code uses `shared`.
    init(userDefaults: UserDefaults = .standard) {
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
        switch service {
        case .openRouter:
            userDefaults.set(enabled, forKey: StorageKeys.openRouterProviderEnabled)
        case .grok:
            userDefaults.set(enabled, forKey: StorageKeys.grokProviderEnabled)
        case .claudeCode, .codexCli, .cursor:
            break
        }
        save()
    }

    private func load() {
        let rawValues = userDefaults.stringArray(forKey: storageKey) ?? []
        hiddenServices = Set(rawValues.compactMap(ServiceType.init(rawValue:)))
        if !userDefaults.bool(forKey: StorageKeys.openRouterProviderEnabled) {
            hiddenServices.insert(.openRouter)
        }
        if !userDefaults.bool(forKey: StorageKeys.grokProviderEnabled) {
            hiddenServices.insert(.grok)
        }
    }

    private func save() {
        let rawValues = hiddenServices.map(\.rawValue).sorted()
        userDefaults.set(rawValues, forKey: storageKey)
    }
}
