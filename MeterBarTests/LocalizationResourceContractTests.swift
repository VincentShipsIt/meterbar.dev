import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class LocalizationResourceContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var appCatalogURL: URL {
        repositoryRoot.appendingPathComponent("MeterBar/Resources/Localizable.xcstrings")
    }

    private var widgetCatalogURL: URL {
        repositoryRoot.appendingPathComponent("MeterBarWidget/Resources/Localizable.xcstrings")
    }

    func testAppAndWidgetOwnIndependentEnglishSourceCatalogs() throws {
        for url in [appCatalogURL, widgetCatalogURL] {
            let catalog = try loadCatalog(at: url)
            XCTAssertEqual(catalog["sourceLanguage"] as? String, "en", url.path)
            XCTAssertEqual(catalog["version"] as? String, "1.0", url.path)
            XCTAssertFalse(try strings(in: catalog).isEmpty, url.path)
        }
    }

    func testHighTrafficVerticalSliceKeysStayInTheExpectedTargetCatalog() throws {
        let appKeys = Set(try strings(in: loadCatalog(at: appCatalogURL)).keys)
        XCTAssertTrue([
            "quota.percent_left",
            "quota.percent_used",
            "quota.amount_left",
            "quota.amount_spent",
            "quota.title.session",
            "quota.title.weekly",
            "quota.title.cursor_models",
            "quota.title.other_models",
            "reset.titled_in",
            "reset.window_reset",
            "reset.exhausted_limits",
            "reset.exhausted_detail",
        ].allSatisfy(appKeys.contains))

        let widgetKeys = Set(try strings(in: loadCatalog(at: widgetCatalogURL)).keys)
        XCTAssertTrue([
            "widget.description",
            "widget.empty.choose_title",
            "widget.health.stale",
            "widget.quota.session",
            "count.more_rows",
            "count.more_usage_rows",
            "widget.burndown.name",
            "widget.burndown.description",
            "burndown.projected_empty",
            "burndown.resets_in",
            "burndown.countdown",
            "burndown.stale",
            "burndown.pace_unavailable",
            "burndown.usage_unavailable",
        ].allSatisfy(widgetKeys.contains))

        let appKeysAfterBurnDown = Set(try strings(in: loadCatalog(at: appCatalogURL)).keys)
        XCTAssertTrue([
            "burndown.projected_empty",
            "burndown.resets_in",
            "burndown.countdown",
            "burndown.stale",
            "burndown.pace_unavailable",
            "burndown.usage_unavailable",
        ].allSatisfy(appKeysAfterBurnDown.contains))
    }

    /// The Settings preview draws the widget's empty states from the app bundle,
    /// so both catalogs have to carry the same four keys with the same English
    /// words. Translated only on one side, the preview would contradict the
    /// widget it is previewing.
    func testWidgetEmptyStateCopyIsCarriedByBothCatalogsWithMatchingEnglish() throws {
        let appStrings = try strings(in: loadCatalog(at: appCatalogURL))
        let widgetStrings = try strings(in: loadCatalog(at: widgetCatalogURL))

        for key in [
            "widget.empty.choose_title",
            "widget.empty.choose_detail",
            "widget.empty.unavailable_title",
            "widget.empty.unavailable_detail",
        ] {
            let appValue = try englishValue(for: key, in: appStrings)
            let widgetValue = try englishValue(for: key, in: widgetStrings)
            XCTAssertEqual(appValue, widgetValue, "\(key) must read identically in both bundles")
        }
    }

    /// One key per `ServiceType.QuotaTitleKey` case. The shared routing decides
    /// which case applies; the widget catalog only supplies its words, so a new
    /// case without a key would silently ship English.
    func testWidgetCatalogCoversEveryQuotaTitleRoutingKey() throws {
        let widgetKeys = Set(try strings(in: loadCatalog(at: widgetCatalogURL)).keys)
        for key in [
            "widget.quota.key_limit",
            "widget.quota.model",
            "widget.quota.on_demand",
            "widget.quota.code_review",
            "widget.quota.cursor_models",
            "widget.quota.session",
            "widget.quota.account_credits",
            "widget.quota.other_models",
            "widget.quota.monthly",
            "widget.quota.weekly",
        ] {
            XCTAssertTrue(widgetKeys.contains(key), "\(key) missing from the widget catalog")
        }
    }

    /// The app-side mirror of the widget contract above. The popover switches
    /// over the same routing key, so a case without an app key would ship
    /// English into every locale.
    func testAppCatalogCoversEveryQuotaTitleRoutingKey() throws {
        let appKeys = Set(try strings(in: loadCatalog(at: appCatalogURL)).keys)
        for key in Self.appQuotaTitleCatalogKeys.map(\.catalogKey) {
            XCTAssertTrue(appKeys.contains(key), "\(key) missing from the app catalog")
        }
    }

    /// Every routing key resolves a real catalog entry rather than falling back
    /// to hardcoded English.
    ///
    /// The SwiftPM test target excludes `MeterBar/Resources`, so
    /// `String(localized:)` here returns its `defaultValue`; comparing that
    /// against the shipped catalog's English value is what proves the key is
    /// present and still says the same words. Rename or delete a key in either
    /// place and this fails instead of silently degrading to English at runtime.
    func testLocalizedQuotaTitleResolvesAnAppCatalogEntryForEveryRoutingKey() throws {
        let appStrings = try strings(in: loadCatalog(at: appCatalogURL))

        for (routingKey, catalogKey) in Self.appQuotaTitleCatalogKeys {
            // Deliberately built with one fixed kind: localization routes off
            // the shared key alone, never off the window it happened to fill.
            let limit = SnapshotLimit(
                id: "quota",
                kind: .session,
                quotaTitleKey: routingKey,
                usageLimit: UsageLimit(used: 4, total: 100, resetTime: nil)
            )
            let catalogEnglish = try englishValue(for: catalogKey, in: appStrings)

            XCTAssertEqual(limit.localizedTitle, catalogEnglish, catalogKey)
            XCTAssertEqual(routingKey.englishTitle, catalogEnglish, catalogKey)
        }
    }

    /// One app catalog key per `ServiceType.QuotaTitleKey` case, spelled out so
    /// a new case has to be given words before it can ship.
    private static let appQuotaTitleCatalogKeys: [(routingKey: ServiceType.QuotaTitleKey, catalogKey: String)] = [
        (.keyLimit, "quota.title.key_limit"),
        (.model(label: nil), "quota.title.model"),
        (.onDemand, "quota.title.on_demand"),
        (.codeReview, "quota.title.code_review"),
        (.cursorModels, "quota.title.cursor_models"),
        (.session, "quota.title.session"),
        (.accountCredits, "quota.title.account_credits"),
        (.otherModels, "quota.title.other_models"),
        (.monthly, "quota.title.monthly"),
        (.weekly, "quota.title.weekly"),
    ]

    func testCountStringsCarryEnglishOneAndOtherPluralRules() throws {
        try assertPluralRules(
            keys: ["reset.exhausted_limits", "reset.exhausted_detail"],
            catalogURL: appCatalogURL
        )
        try assertPluralRules(
            keys: ["count.more_rows", "count.more_usage_rows"],
            catalogURL: widgetCatalogURL
        )
    }

    /// Localization must never redefine these as display copy. They are CLI
    /// protocol tokens consumed by shell scripts and JSON clients.
    func testCLIMachineTokensRemainStableAndOutsideTheCatalogs() throws {
        XCTAssertEqual(
            ServiceType.allCases.sorted { $0.sortOrder < $1.sortOrder }.map(\.cliIdentifier),
            ["claude", "codex", "cursor", "openrouter", "grok"]
        )

        let reservedTokens: Set<String> = [
            "usage",
            "cost",
            "doctor",
            "guard",
            "session",
            "weekly",
            "codeReview",
            "schemaVersion",
        ]
        let catalogKeys = Set(try strings(in: loadCatalog(at: appCatalogURL)).keys)
            .union(try strings(in: loadCatalog(at: widgetCatalogURL)).keys)
        XCTAssertTrue(reservedTokens.isDisjoint(with: catalogKeys))
    }

    private func loadCatalog(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Invalid String Catalog JSON at \(url.path)"
        )
    }

    private func strings(in catalog: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(catalog["strings"] as? [String: Any])
    }

    private func englishValue(for key: String, in catalogStrings: [String: Any]) throws -> String {
        let entry = try XCTUnwrap(catalogStrings[key] as? [String: Any], key)
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
        let english = try XCTUnwrap(localizations["en"] as? [String: Any], key)
        let unit = try XCTUnwrap(english["stringUnit"] as? [String: Any], key)
        return try XCTUnwrap(unit["value"] as? String, key)
    }

    private func assertPluralRules(keys: [String], catalogURL: URL) throws {
        let catalogStrings = try strings(in: loadCatalog(at: catalogURL))
        for key in keys {
            let entry = try XCTUnwrap(catalogStrings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            let english = try XCTUnwrap(localizations["en"] as? [String: Any], key)
            let variations = try XCTUnwrap(english["variations"] as? [String: Any], key)
            let plural = try XCTUnwrap(variations["plural"] as? [String: Any], key)
            XCTAssertNotNil(plural["one"], "\(key) needs an English one rule")
            XCTAssertNotNil(plural["other"], "\(key) needs an English other rule")
        }
    }
}
