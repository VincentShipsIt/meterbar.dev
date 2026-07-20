import AppKit
import MeterBarShared
@testable import MeterBar
import SwiftUI
import XCTest

@MainActor
final class WidgetSettingsTests: XCTestCase {
    func testWidgetRouteIsBetweenProvidersAndAPIUsage() {
        XCTAssertEqual(
            SettingsSection.allCases,
            [.general, .providers, .widget, .apiUsage, .cost, .automation, .about]
        )
        XCTAssertEqual(SettingsSection.widget.iconName, "rectangle.3.group")
    }

    func testAccountProjectionIncludesOnlyEnabledProvidersAndAccounts() {
        let enabledClaude = ClaudeCodeAccount(
            id: UUID(),
            name: "Claude Work",
            configDirectory: nil
        )
        let disabledClaude = ClaudeCodeAccount(
            id: UUID(),
            name: "Claude Disabled",
            configDirectory: nil,
            isEnabled: false
        )
        let enabledCodex = CodexAccount(
            id: UUID(),
            name: "Codex Work",
            homeDirectory: nil
        )
        let options = WidgetSettingsAccountProjection.options(
            enabledServices: [.claudeCode, .codexCli, .cursor],
            claudeAccounts: [enabledClaude, disabledClaude],
            codexAccounts: [enabledCodex]
        )

        XCTAssertEqual(options.map(\.name), ["Claude Work", "Codex Work", "Cursor"])
        XCTAssertEqual(options.map(\.service), [.claudeCode, .codexCli, .cursor])
        XCTAssertFalse(options.contains { $0.name == disabledClaude.name })
    }

    func testAccountProjectionHandlesEmptyEnabledAccountLists() {
        let options = WidgetSettingsAccountProjection.options(
            enabledServices: [.claudeCode, .codexCli],
            claudeAccounts: [],
            codexAccounts: []
        )

        XCTAssertTrue(options.isEmpty)
    }

    func testSelectionTransitionsBetweenSelectAllAndExplicit() {
        let claude = WidgetAccountIdentifier.provider(.claudeCode)
        let codex = WidgetAccountIdentifier.provider(.codexCli)
        let available: Set<WidgetAccountIdentifier> = [claude, codex]

        let explicit = WidgetSettingsSelection.toggling(
            claude,
            isSelected: false,
            selection: .all,
            availableIdentifiers: available
        )
        XCTAssertEqual(explicit.mode, .explicit)
        XCTAssertEqual(explicit.explicitIdentifiers, [codex])

        let all = WidgetSettingsSelection.toggling(
            claude,
            isSelected: true,
            selection: explicit,
            availableIdentifiers: available
        )
        XCTAssertEqual(all, .all)
        XCTAssertTrue(WidgetSettingsSelection.contains(claude, selection: all))
        XCTAssertTrue(WidgetSettingsSelection.contains(codex, selection: all))
    }

    func testPlaceholderPreviewUsesEverySupportedFamilyAndCurrentPreferences() {
        let options = [
            WidgetSettingsAccountOption(
                id: .provider(.cursor),
                service: .cursor,
                name: "Cursor"
            )
        ]
        let data = WidgetSettingsPreviewData.make(
            options: options,
            metrics: [:],
            claudeAccountMetrics: [:],
            codexAccountMetrics: [:],
            now: Date(timeIntervalSinceReferenceDate: 1_000_000)
        )
        var preferences = WidgetPreferences.defaults
        preferences.displayMode = .remaining

        XCTAssertTrue(data.usesPlaceholders)
        for family in WidgetPresentationFamily.allCases {
            let presentation = WidgetPresentationPlanner.makePresentation(
                metrics: data.metrics,
                accountMetrics: data.accountMetrics,
                preferences: preferences,
                family: family,
                now: Date(timeIntervalSinceReferenceDate: 1_000_000)
            )
            XCTAssertNil(presentation.emptyState, "\(family)")
            XCTAssertEqual(presentation.rows.first?.displayMode, .remaining, "\(family)")
        }
    }

    func testWidgetSettingsAndAllPreviewAppearancesRender() {
        let settingsView = NSHostingView(rootView: WidgetSettingsView().frame(width: 720))
        settingsView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(settingsView.fittingSize.height, 0)

        let data = WidgetSettingsPreviewData.make(
            options: [
                WidgetSettingsAccountOption(
                    id: .provider(.cursor),
                    service: .cursor,
                    name: "Cursor"
                )
            ],
            metrics: [:],
            claudeAccountMetrics: [:],
            codexAccountMetrics: [:]
        )
        for appearance in WidgetSettingsPreviewAppearance.allCases {
            let gallery = NSHostingView(
                rootView: WidgetSettingsPreviewGallery(
                    data: data,
                    preferences: .defaults,
                    appearance: appearance
                )
            )
            gallery.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(gallery.fittingSize.height, 0, appearance.title)
        }
    }
}
