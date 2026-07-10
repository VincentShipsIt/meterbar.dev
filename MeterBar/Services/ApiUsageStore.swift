import Combine
import CryptoKit
import Foundation

/// Holds the fetched organization API usage per provider and the user-selected
/// reporting window. Refetches when the window changes or on manual refresh.
/// Only providers with an admin key entered are fetched.
@MainActor
final class ApiUsageStore: ObservableObject {
    typealias UsageFetcher = (ApiProvider, String, ApiUsageWindow) async throws -> ApiUsage

    private enum CacheWindow: Hashable {
        case last7Days
        case last30Days
        case custom(start: Date, end: Date)

        init(_ window: ApiUsageWindow) {
            switch window {
            case .last7Days:
                self = .last7Days
            case .last30Days:
                self = .last30Days
            case .custom:
                let range = window.dateRange()
                self = .custom(start: range.start, end: range.end)
            }
        }
    }

    private struct ProviderCredential {
        let provider: ApiProvider
        let adminKey: String
        let identity: Data
    }

    private struct CacheEntry {
        let credentialIdentity: Data
        let usage: ApiUsage
    }

    static let shared = ApiUsageStore()

    @Published private(set) var usage: [ApiProvider: ApiUsage] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var window: ApiUsageWindow = .last7Days

    private let authenticatedProvidersSource: () -> [ApiProvider]
    private let adminKeySource: (ApiProvider) -> String?
    private let fetchUsage: UsageFetcher
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var activeWindow: ApiUsageWindow?
    private var activeCredentialIdentities: [ApiProvider: Data]?
    private var cache: [CacheWindow: [ApiProvider: CacheEntry]] = [:]

    init(
        authenticatedProviders: (() -> [ApiProvider])? = nil,
        adminKey: ((ApiProvider) -> String?)? = nil,
        fetchUsage: UsageFetcher? = nil
    ) {
        let authManager = AuthenticationManager.shared
        authenticatedProvidersSource = authenticatedProviders ?? {
            ApiProvider.allCases.filter { authManager.isAuthenticated($0) }
        }
        adminKeySource = adminKey ?? { authManager.adminKey(for: $0) }
        self.fetchUsage = fetchUsage ?? { provider, adminKey, window in
            try await ApiUsageService.fetch(provider: provider, adminKey: adminKey, window: window)
        }
    }

    /// Providers the user has entered an admin key for (drives which cards show).
    var authenticatedProviders: [ApiProvider] {
        authenticatedProvidersSource()
    }

    var hasAnyAuthenticated: Bool {
        !authenticatedProviders.isEmpty
    }

    func setWindow(_ newWindow: ApiUsageWindow) {
        guard newWindow != window else { return }
        window = newWindow
        startRefresh(for: newWindow)
    }

    func refresh() async {
        let currentIdentities = credentialIdentities(for: currentCredentials())
        if activeWindow == window,
           activeCredentialIdentities == currentIdentities,
           let refreshTask {
            await refreshTask.value
            return
        }
        let task = startRefresh(for: window)
        await task.value
    }

    /// Awaits work already scheduled by `setWindow`. Kept internal so focused
    /// store tests can observe the same path the SwiftUI picker uses.
    func waitForCurrentRefresh() async {
        await refreshTask?.value
    }

    @discardableResult
    private func startRefresh(for requestedWindow: ApiUsageWindow) -> Task<Void, Never> {
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask?.cancel()

        let credentials = currentCredentials()
        let identities = credentialIdentities(for: credentials)
        let cacheWindow = CacheWindow(requestedWindow)
        pruneCache(for: identities)

        activeWindow = requestedWindow
        activeCredentialIdentities = identities
        usage = cachedUsage(for: cacheWindow, credentialIdentities: identities)
        lastError = nil
        isLoading = !credentials.isEmpty

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(
                for: requestedWindow,
                cacheWindow: cacheWindow,
                credentials: credentials,
                credentialIdentities: identities,
                generation: generation
            )
        }
        refreshTask = task
        return task
    }

    private func performRefresh(
        for requestedWindow: ApiUsageWindow,
        cacheWindow: CacheWindow,
        credentials: [ProviderCredential],
        credentialIdentities: [ApiProvider: Data],
        generation: Int
    ) async {
        guard generation == refreshGeneration else { return }

        guard !credentials.isEmpty else {
            cache = [:]
            usage = [:]
            lastError = nil
            isLoading = false
            activeWindow = nil
            activeCredentialIdentities = nil
            return
        }

        var results: [ApiProvider: ApiUsage] = [:]
        var refreshError: String?
        for credential in credentials {
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            do {
                results[credential.provider] = try await fetchUsage(
                    credential.provider,
                    credential.adminKey,
                    requestedWindow
                )
            } catch {
                guard !Task.isCancelled else { return }
                refreshError = ServiceSupport.safeErrorMessage(for: error)
                if let cached = cache[cacheWindow]?[credential.provider],
                   cached.credentialIdentity == credential.identity {
                    results[credential.provider] = cached.usage
                }
            }
        }

        guard !Task.isCancelled, generation == refreshGeneration else { return }

        let latestIdentities = self.credentialIdentities(for: currentCredentials())
        guard latestIdentities == credentialIdentities else {
            pruneCache(for: latestIdentities)
            usage = cachedUsage(for: CacheWindow(window), credentialIdentities: latestIdentities)
            lastError = nil
            isLoading = false
            activeWindow = nil
            activeCredentialIdentities = nil
            return
        }

        var updatedCache: [ApiProvider: CacheEntry] = [:]
        for credential in credentials {
            if let result = results[credential.provider] {
                updatedCache[credential.provider] = CacheEntry(
                    credentialIdentity: credential.identity,
                    usage: result
                )
            }
        }
        if updatedCache.isEmpty {
            cache.removeValue(forKey: cacheWindow)
        } else {
            cache[cacheWindow] = updatedCache
        }

        usage = results
        lastError = refreshError
        isLoading = false
        activeWindow = nil
        activeCredentialIdentities = nil
    }

    private func currentCredentials() -> [ProviderCredential] {
        authenticatedProviders.compactMap { provider in
            guard let adminKey = adminKeySource(provider) else { return nil }
            return ProviderCredential(
                provider: provider,
                adminKey: adminKey,
                identity: Self.credentialIdentity(for: adminKey)
            )
        }
    }

    private func credentialIdentities(
        for credentials: [ProviderCredential]
    ) -> [ApiProvider: Data] {
        Dictionary(uniqueKeysWithValues: credentials.map { ($0.provider, $0.identity) })
    }

    private func cachedUsage(
        for window: CacheWindow,
        credentialIdentities: [ApiProvider: Data]
    ) -> [ApiProvider: ApiUsage] {
        guard let entries = cache[window] else { return [:] }
        return entries.reduce(into: [:]) { result, item in
            let (provider, entry) = item
            if credentialIdentities[provider] == entry.credentialIdentity {
                result[provider] = entry.usage
            }
        }
    }

    private func pruneCache(for credentialIdentities: [ApiProvider: Data]) {
        for window in Array(cache.keys) {
            let matchingEntries = cache[window]?.filter { item in
                credentialIdentities[item.key] == item.value.credentialIdentity
            } ?? [:]
            if matchingEntries.isEmpty {
                cache.removeValue(forKey: window)
            } else {
                cache[window] = matchingEntries
            }
        }
    }

    private static func credentialIdentity(for adminKey: String) -> Data {
        Data(SHA256.hash(data: Data(adminKey.utf8)))
    }
}
