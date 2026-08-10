import Combine
import Foundation

/// Persists the optional presentation-only currency conversion.
///
/// Automatic mode detects the currency configured in macOS Region settings,
/// refreshes it from the ECB at most once per day, and keeps the last
/// successful quote for offline use. Manual mode remains available for a
/// currency the ECB does not publish. Stored and exported cost data stays USD.
final class DisplayCurrencyStore: ObservableObject {
    static let shared = DisplayCurrencyStore()

    @Published private(set) var currency: DisplayCurrency?
    @Published private(set) var isAutomatic: Bool
    @Published private(set) var isRefreshingAutomaticRate = false
    @Published private(set) var automaticRateError: String?

    var detectedCurrencyCode: String? {
        Self.normalizedCode(localeCurrencyCode())
    }

    private static let automaticRefreshInterval: TimeInterval = 24 * 60 * 60

    private let userDefaults: UserDefaults
    private let fetchAutomaticRate: (String) async throws -> DisplayCurrencyRateQuote
    private let localeCurrencyCode: () -> String?
    private let now: () -> Date

    /// Internal seams keep locale, time, networking, and persistence fully
    /// deterministic in tests. Production uses the official ECB client.
    init(
        userDefaults: UserDefaults = .standard,
        fetchAutomaticRate: ((String) async throws -> DisplayCurrencyRateQuote)? = nil,
        localeCurrencyCode: @escaping () -> String? = { Locale.autoupdatingCurrent.currency?.identifier },
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.fetchAutomaticRate = fetchAutomaticRate ?? { code in
            try await DisplayCurrencyRateClient().fetchRate(for: code)
        }
        self.localeCurrencyCode = localeCurrencyCode
        self.now = now
        currency = nil
        isAutomatic = false
        load()

        if userDefaults.object(forKey: StorageKeys.displayCurrencyAutomatic) != nil {
            isAutomatic = userDefaults.bool(forKey: StorageKeys.displayCurrencyAutomatic)
        } else {
            // Preserve an existing manual conversion during migration. Fresh
            // installs have no conversion and opt into the useful default.
            isAutomatic = currency == nil
        }
    }

    /// Read-only projection used by CLI-oriented call sites and tests.
    init(currency: DisplayCurrency?) {
        userDefaults = .standard
        fetchAutomaticRate = { code in
            throw DisplayCurrencyRateError.unsupportedCurrency(code)
        }
        localeCurrencyCode = { nil }
        now = Date.init
        self.currency = currency
        isAutomatic = false
    }

    /// Saves an explicit manual rate and disables background replacement.
    func set(code: String, rate: Double) {
        let trimmedCode = Self.normalizedCode(code) ?? ""
        guard !trimmedCode.isEmpty, rate > 0, rate.isFinite else {
            clear()
            return
        }
        let next = DisplayCurrency(
            code: trimmedCode,
            unitsPerUSD: rate,
            enteredAt: now(),
            source: .manual
        )
        isAutomatic = false
        automaticRateError = nil
        userDefaults.set(false, forKey: StorageKeys.displayCurrencyAutomatic)
        userDefaults.removeObject(forKey: StorageKeys.displayCurrencyLastRefreshAt)
        currency = next
        persist(next)
    }

    func setAutomaticEnabled(_ enabled: Bool) {
        isAutomatic = enabled
        automaticRateError = nil
        userDefaults.set(enabled, forKey: StorageKeys.displayCurrencyAutomatic)
    }

    /// Refreshes only when automatic mode is enabled and the cached fetch is
    /// stale, unless the user explicitly requested `force` from Settings.
    /// Failures never discard the last-known-good quote.
    func refreshAutomaticCurrency(force: Bool = false) async {
        guard isAutomatic, !isRefreshingAutomaticRate else { return }
        guard let code = detectedCurrencyCode else {
            automaticRateError = "Choose a currency in macOS Region settings or enter a manual rate."
            return
        }

        let refreshDate = userDefaults.object(forKey: StorageKeys.displayCurrencyLastRefreshAt) as? Date
        let cacheMatches = currency?.code == code && currency?.source != .manual
        if !force,
           cacheMatches,
           let refreshDate,
           now().timeIntervalSince(refreshDate) < Self.automaticRefreshInterval {
            return
        }

        isRefreshingAutomaticRate = true
        automaticRateError = nil
        defer { isRefreshingAutomaticRate = false }

        do {
            let next: DisplayCurrency
            if code == "USD" {
                next = DisplayCurrency(
                    code: "USD",
                    unitsPerUSD: 1,
                    enteredAt: now(),
                    source: .system
                )
            } else {
                let quote = try await fetchAutomaticRate(code)
                guard quote.unitsPerUSD > 0, quote.unitsPerUSD.isFinite else {
                    throw DisplayCurrencyRateError.invalidPayload
                }
                next = DisplayCurrency(
                    code: quote.code,
                    unitsPerUSD: quote.unitsPerUSD,
                    enteredAt: quote.referenceDate,
                    source: .europeanCentralBank
                )
            }

            currency = next
            persist(next)
            userDefaults.set(true, forKey: StorageKeys.displayCurrencyAutomatic)
            userDefaults.set(now(), forKey: StorageKeys.displayCurrencyLastRefreshAt)
        } catch let error as DisplayCurrencyRateError {
            automaticRateError = error.localizedDescription + offlineFallbackSuffix
        } catch {
            automaticRateError = "The automatic exchange rate could not be updated." + offlineFallbackSuffix
        }
    }

    /// Removes the saved conversion and disables automatic mode so choosing
    /// "Show USD" remains stable across view appearances.
    func clear() {
        currency = nil
        isAutomatic = false
        automaticRateError = nil
        userDefaults.set(false, forKey: StorageKeys.displayCurrencyAutomatic)
        userDefaults.removeObject(forKey: StorageKeys.displayCurrencyCode)
        userDefaults.removeObject(forKey: StorageKeys.displayCurrencyRate)
        userDefaults.removeObject(forKey: StorageKeys.displayCurrencyEnteredAt)
        userDefaults.removeObject(forKey: StorageKeys.displayCurrencySource)
        userDefaults.removeObject(forKey: StorageKeys.displayCurrencyLastRefreshAt)
    }

    private var offlineFallbackSuffix: String {
        currency == nil ? " Enter a manual rate instead." : " The last saved rate is still in use."
    }

    private static func normalizedCode(_ code: String?) -> String? {
        guard let code else { return nil }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func persist(_ currency: DisplayCurrency) {
        userDefaults.set(currency.code, forKey: StorageKeys.displayCurrencyCode)
        userDefaults.set(currency.unitsPerUSD, forKey: StorageKeys.displayCurrencyRate)
        userDefaults.set(currency.enteredAt, forKey: StorageKeys.displayCurrencyEnteredAt)
        userDefaults.set(currency.source.rawValue, forKey: StorageKeys.displayCurrencySource)
    }

    private func load() {
        guard
            let code = Self.normalizedCode(userDefaults.string(forKey: StorageKeys.displayCurrencyCode)),
            userDefaults.object(forKey: StorageKeys.displayCurrencyRate) != nil
        else {
            currency = nil
            return
        }
        let rate = userDefaults.double(forKey: StorageKeys.displayCurrencyRate)
        guard rate > 0, rate.isFinite else {
            currency = nil
            return
        }
        let enteredAt = userDefaults.object(forKey: StorageKeys.displayCurrencyEnteredAt) as? Date ?? now()
        let source = userDefaults.string(forKey: StorageKeys.displayCurrencySource)
            .flatMap(DisplayCurrencySource.init(rawValue:)) ?? .manual
        currency = DisplayCurrency(
            code: code,
            unitsPerUSD: rate,
            enteredAt: enteredAt,
            source: source
        )
    }
}
