import Combine
import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

/// Release channel the updater points Sparkle at. Stable uses the feed baked
/// into Info.plist (`SUFeedURL`); Nightly swaps to the rolling master feed at
/// runtime via the updater delegate, so one installed app can test master
/// builds without a full release.
enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case nightly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stable: "Stable"
        case .nightly: "Nightly"
        }
    }
}

/// Owns Sparkle's standard updater and exposes only user-controlled update actions.
/// Automatic network checks remain off until the user explicitly enables them.
final class SoftwareUpdateController: ObservableObject {
    static let shared = SoftwareUpdateController()

    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var configurationError: String?
    /// Currently selected release channel. Persisted across launches.
    @Published private(set) var channel: UpdateChannel = .stable

    /// UserDefaults key holding the persisted `UpdateChannel.rawValue`.
    static let channelStorageKey = "MeterBarUpdateChannel"

    /// Rolling nightly feed. Uses the fixed `nightly` pre-release tag (not
    /// `/latest/`, which resolves only to non-prerelease releases) so the URL is
    /// permanent. Signed with the same EdDSA key as stable.
    static let nightlyFeedURLString =
        "https://github.com/VincentShipsIt/meterbar.dev/releases/download/nightly/appcast-nightly.xml"

    /// Feed override for a channel. `nil` means "use the Info.plist `SUFeedURL`"
    /// (the stable feed), which is exactly what Sparkle expects from
    /// `feedURLString(for:)` when no override applies.
    static func resolvedFeedURLString(for channel: UpdateChannel) -> String? {
        switch channel {
        case .stable: nil
        case .nightly: nightlyFeedURLString
        }
    }

    static func loadChannel(from defaults: UserDefaults) -> UpdateChannel {
        guard let raw = defaults.string(forKey: channelStorageKey),
              let channel = UpdateChannel(rawValue: raw) else {
            return .stable
        }
        return channel
    }

    static func persistChannel(_ channel: UpdateChannel, to defaults: UserDefaults) {
        defaults.set(channel.rawValue, forKey: channelStorageKey)
    }

    /// True only for a plausible Ed25519 public key. Debug and PR-gate builds
    /// carry the unsubstituted `$(SPARKLE_PUBLIC_ED_KEY)` build variable in
    /// their Info.plist, which the empty-string check alone would let through.
    nonisolated static func isUsableEDPublicKey(_ rawValue: String) -> Bool {
        let key = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.hasPrefix("$("), !key.hasPrefix("${") else { return false }
        guard let decoded = Data(base64Encoded: key) else { return false }
        return decoded.count == 32
    }

    private let userDefaults: UserDefaults

#if canImport(Sparkle)
    private let controller: SPUStandardUpdaterController?
    private let channelDelegate: ChannelUpdaterDelegate
    private var cancellables = Set<AnyCancellable>()

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        userDefaults = defaults
        let channel = Self.loadChannel(from: defaults)
        self.channel = channel
        // Sparkle references the updater delegate weakly, so the controller must
        // retain it. Created before the guard so every stored property is set on
        // the unusable-key early return too.
        let delegate = ChannelUpdaterDelegate(channel: channel)
        channelDelegate = delegate

        guard let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Self.isUsableEDPublicKey(publicKey) else {
            controller = nil
            configurationError = "Software updates are unavailable in this build."
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
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

    /// Switch release channel: persist it, repoint the updater's feed, then look
    /// for a build on the new channel immediately (Sparkle re-queries the
    /// delegate on each check, so the swapped feed takes effect right away).
    func setChannel(_ channel: UpdateChannel) {
        guard channel != self.channel else { return }
        self.channel = channel
        Self.persistChannel(channel, to: userDefaults)
        channelDelegate.channel = channel
        refreshState()
        if canCheckForUpdates {
            checkForUpdates()
        }
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

    /// Retains Sparkle's updater delegate and overrides the feed per channel.
    /// `channel` is mutated by `setChannel` so a live channel switch is picked up
    /// on the next update check without recreating the updater.
    private final class ChannelUpdaterDelegate: NSObject, SPUUpdaterDelegate {
        var channel: UpdateChannel

        init(channel: UpdateChannel) {
            self.channel = channel
        }

        func feedURLString(for updater: SPUUpdater) -> String? {
            SoftwareUpdateController.resolvedFeedURLString(for: channel)
        }
    }
#else
    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        _ = bundle
        userDefaults = defaults
        channel = Self.loadChannel(from: defaults)
        configurationError = "Software updates are available in the app build."
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        _ = enabled
    }

    func setChannel(_ channel: UpdateChannel) {
        self.channel = channel
        Self.persistChannel(channel, to: userDefaults)
    }

    func checkForUpdates() {
        // The standalone Swift package intentionally has no updater framework.
    }

    func refreshState() {
        // The standalone Swift package intentionally has no updater framework.
    }
#endif
}
