import Combine
import Foundation

/// Persists the presentation-only USD/EUR choice.
///
/// USD is the default and needs no conversion. EUR refreshes from the ECB at
/// most once per day and keeps the last successful quote for offline use.
/// Stored and exported cost data always stays USD.
final class DisplayCurrencyStore: ObservableObject {
    static let shared = DisplayCurrencyStore()

    @Published private(set) var currency: DisplayCurrency?
    @Published private(set) var selection: DisplayCurrencySelection
    @Published private(set) var isRefreshingAutomaticRate = false
    @Published private(set) var automaticRateError: String?

    private static let automaticRefreshInterval: TimeInterval = 24 * 60 * 60

    private let userDefaults: UserDefaults
    private let fetchAutomaticRate: (String) async throws -> DisplayCurrencyRateQuote
    private let now: () -> Date

    /// Internal seams keep time, networking, and persistence fully
    /// deterministic in tests. Production uses the official ECB client.
    init(
        userDefaults: UserDefaults = .standard,
        fetchAutomaticRate: ((String) async throws -> DisplayCurrencyRateQuote)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.fetchAutomaticRate = fetchAutomaticRate ?? { code in
            try await DisplayCurrencyRateClient().fetchRate(for: code)
        }
        self.now = now
        currency = nil
        selection = .usd
        load()

        if let saved = userDefaults.string(forKey: StorageKeys.displayCurrencySelection)
            .flatMap(DisplayCurrencySelection.init(rawValue:)) {
            selection = saved
        }

        if selection == .usd {
            clearSavedRate()
        } else if currency?.code != DisplayCurrencySelection.eur.rawValue {
            currency = nil
        }
        userDefaults.set(selection.rawValue, forKey: StorageKeys.displayCurrencySelection)
    }

    /// Read-only projection used by CLI-oriented call sites and tests.
    init(currency: DisplayCurrency?) {
        userDefaults = .standard
        fetchAutomaticRate = { code in
            throw DisplayCurrencyRateError.unsupportedCurrency(code)
        }
        now = Date.init
        self.currency = currency
        selection = currency?.code == DisplayCurrencySelection.eur.rawValue ? .eur : .usd
    }

    func setSelection(_ nextSelection: DisplayCurrencySelection) {
        selection = nextSelection
        automaticRateError = nil
        userDefaults.set(nextSelection.rawValue, forKey: StorageKeys.displayCurrencySelection)

        if nextSelection == .usd {
            clearSavedRate()
        }
    }

    /// Refreshes EUR only when its cached quote is stale, unless the user
    /// explicitly requested `force` from Settings.
    /// Failures never discard the last-known-good quote.
    func refreshAutomaticCurrency(force: Bool = false) async {
        guard selection == .eur, !isRefreshingAutomaticRate else { return }
        let code = DisplayCurrencySelection.eur.rawValue

        let refreshDate = userDefaults.object(forKey: StorageKeys.displayCurrencyLastRefreshAt) as? Date
        let cacheMatches = currency?.code == code
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
            let quote = try await fetchAutomaticRate(code)
            guard selection == .eur else { return }
            let normalizedCode = quote.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard normalizedCode == code,
                  quote.unitsPerUSD > 0,
                  quote.unitsPerUSD.isFinite else {
                throw DisplayCurrencyRateError.invalidPayload
            }
            let next = DisplayCurrency(
                code: normalizedCode,
                unitsPerUSD: quote.unitsPerUSD,
                enteredAt: quote.referenceDate,
                source: .europeanCentralBank
            )

            currency = next
            persist(next)
            userDefaults.set(now(), forKey: StorageKeys.displayCurrencyLastRefreshAt)
        } catch let error as DisplayCurrencyRateError {
            automaticRateError = error.localizedDescription + offlineFallbackSuffix
        } catch {
            automaticRateError = "The automatic exchange rate could not be updated." + offlineFallbackSuffix
        }
    }

    private func clearSavedRate() {
        currency = nil
        automaticRateError = nil
        userDefaults.removeObject(forKey: StorageKeys.displayCurrencyCode)
        userDefaults.removeObject(forKey: StorageKeys.displayCurrencyRate)
        userDefaults.removeObject(forKey: StorageKeys.displayCurrencyEnteredAt)
        userDefaults.removeObject(forKey: StorageKeys.displayCurrencySource)
        userDefaults.removeObject(forKey: StorageKeys.displayCurrencyLastRefreshAt)
    }

    private var offlineFallbackSuffix: String {
        if currency == nil {
            return " Totals remain in USD until a EUR rate is available."
        }
        return " The last saved rate is still in use."
    }

    private func persist(_ currency: DisplayCurrency) {
        userDefaults.set(currency.code, forKey: StorageKeys.displayCurrencyCode)
        userDefaults.set(currency.unitsPerUSD, forKey: StorageKeys.displayCurrencyRate)
        userDefaults.set(currency.enteredAt, forKey: StorageKeys.displayCurrencyEnteredAt)
        userDefaults.set(currency.source.rawValue, forKey: StorageKeys.displayCurrencySource)
    }

    private func load() {
        guard
            let code = userDefaults.string(forKey: StorageKeys.displayCurrencyCode)?.uppercased(),
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
