import Combine
import Foundation

/// Persists the user's optional presentation-only currency conversion
/// (issue #270). MeterBar never fetches a live exchange rate: `currency` is
/// exactly what the user typed, paired with the moment they entered it, so a
/// converted figure is never mistaken for a live quote. `nil` means "no
/// conversion, show USD" — the default and the only state that ships out of
/// the box.
final class DisplayCurrencyStore: ObservableObject {
    static let shared = DisplayCurrencyStore()

    @Published private(set) var currency: DisplayCurrency?

    private let userDefaults: UserDefaults

    /// Internal (not private) so tests can construct an instance backed by an
    /// isolated `UserDefaults` suite; production code uses `shared`.
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        load()
    }

    /// Read-only projection for the CLI, mirroring `ProviderVisibilityStore`'s
    /// second initializer — no `UserDefaults` access, just the decoded value.
    init(currency: DisplayCurrency?) {
        userDefaults = .standard
        self.currency = currency
    }

    /// Saves a new rate. `code` is trimmed and uppercased for display
    /// consistency. A rate that is non-positive, infinite, or NaN can never
    /// produce a meaningful converted figure, so it clears the conversion
    /// instead of saving one. (`Double.infinity` passes `> 0`, so the finite
    /// check has to be explicit or every converted total becomes "inf".)
    func set(code: String, rate: Double) {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmedCode.isEmpty, rate > 0, rate.isFinite else {
            clear()
            return
        }
        let next = DisplayCurrency(code: trimmedCode, unitsPerUSD: rate, enteredAt: Date())
        currency = next
        persist(next)
    }

    /// Removes any saved conversion, reverting cost views to plain USD.
    func clear() {
        currency = nil
        userDefaults.removeObject(forKey: StorageKeys.displayCurrencyCode)
        userDefaults.removeObject(forKey: StorageKeys.displayCurrencyRate)
        userDefaults.removeObject(forKey: StorageKeys.displayCurrencyEnteredAt)
    }

    private func persist(_ currency: DisplayCurrency) {
        userDefaults.set(currency.code, forKey: StorageKeys.displayCurrencyCode)
        userDefaults.set(currency.unitsPerUSD, forKey: StorageKeys.displayCurrencyRate)
        userDefaults.set(currency.enteredAt, forKey: StorageKeys.displayCurrencyEnteredAt)
    }

    private func load() {
        guard
            let code = userDefaults.string(forKey: StorageKeys.displayCurrencyCode),
            !code.isEmpty,
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
        let enteredAt = userDefaults.object(forKey: StorageKeys.displayCurrencyEnteredAt) as? Date ?? Date()
        currency = DisplayCurrency(code: code, unitsPerUSD: rate, enteredAt: enteredAt)
    }
}
