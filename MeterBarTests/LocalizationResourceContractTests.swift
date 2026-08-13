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
