import Combine
import Foundation

/// Holds the fetched organization API usage per provider and the user-selected
/// reporting window. Refetches when the window changes or on manual refresh.
/// Only providers with an admin key entered are fetched.
@MainActor
final class ApiUsageStore: ObservableObject {
    static let shared = ApiUsageStore()

    @Published private(set) var usage: [ApiProvider: ApiUsage] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var window: ApiUsageWindow = .last7Days

    private let authManager = AuthenticationManager.shared

    private init() {}

    /// Providers the user has entered an admin key for (drives which cards show).
    var authenticatedProviders: [ApiProvider] {
        ApiProvider.allCases.filter { authManager.isAuthenticated($0) }
    }

    var hasAnyAuthenticated: Bool {
        !authenticatedProviders.isEmpty
    }

    func setWindow(_ newWindow: ApiUsageWindow) {
        guard newWindow != window else { return }
        window = newWindow
        Task { await refresh() }
    }

    func refresh() async {
        guard !isLoading else { return }

        let providers = authenticatedProviders
        guard !providers.isEmpty else {
            usage = [:]
            return
        }

        isLoading = true
        lastError = nil
        defer { isLoading = false }

        var results: [ApiProvider: ApiUsage] = [:]
        for provider in providers {
            guard let key = authManager.adminKey(for: provider) else { continue }
            do {
                results[provider] = try await ApiUsageService.fetch(
                    provider: provider,
                    adminKey: key,
                    window: window
                )
            } catch {
                lastError = (error as? ServiceError)?.errorDescription ?? error.localizedDescription
                if let cached = usage[provider] {
                    results[provider] = cached
                }
            }
        }
        usage = results
    }
}
