import Combine
import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

/// Owns Sparkle's standard updater and exposes only user-controlled update actions.
/// Automatic network checks remain off until the user explicitly enables them.
final class SoftwareUpdateController: ObservableObject {
    static let shared = SoftwareUpdateController()

    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var configurationError: String?

#if canImport(Sparkle)
    private let controller: SPUStandardUpdaterController?
    private var cancellables = Set<AnyCancellable>()

    init(bundle: Bundle = .main) {
        guard let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            controller = nil
            configurationError = "Software updates are unavailable in this build."
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        controller.updater.publisher(for: \.automaticallyChecksForUpdates, options: [.initial, .new])
            .sink { [weak self] enabled in
                self?.automaticallyChecksForUpdates = enabled
            }
            .store(in: &cancellables)
        controller.updater.publisher(for: \.canCheckForUpdates, options: [.initial, .new])
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
            .store(in: &cancellables)
        refreshState()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        refreshState()
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
        refreshState()
    }

    func refreshState() {
        guard let updater = controller?.updater else {
            automaticallyChecksForUpdates = false
            canCheckForUpdates = false
            return
        }
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        canCheckForUpdates = updater.canCheckForUpdates
    }
#else
    init(bundle: Bundle = .main) {
        _ = bundle
        configurationError = "Software updates are available in the app build."
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        _ = enabled
    }

    func checkForUpdates() {
        // The standalone Swift package intentionally has no updater framework.
    }

    func refreshState() {
        // The standalone Swift package intentionally has no updater framework.
    }
#endif
}
