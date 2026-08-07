import AppKit
@testable import MeterBar
import SwiftUI
import XCTest

/// Guards the settings row's two-column geometry and the copy that column width
/// was hiding. The row used to pin its label to a fixed 190pt column and its
/// control to a fixed 240pt one, so a multi-sentence `detail` wrapped to six or
/// eight lines while ~300pt of the pane sat empty — and a 260pt control (the
/// provider API-key field) overflowed its 240pt slot. Both directions are
/// asserted here: the label must grow into free space, and the control must be
/// sized by what it holds rather than by a constant.
@MainActor
final class SettingsRowLayoutTests: XCTestCase {
    // MARK: - Metrics

    func testControlColumnAccommodatesTheWidestShippedControl() {
        // ProviderSettingsView's API-key SecureField is 260pt and QuotaEvent's
        // webhook field caps at 300pt. A ceiling below either clips a real row.
        XCTAssertGreaterThanOrEqual(SettingsRowViewMetrics.controlMaxWidth, 300)
        XCTAssertLessThanOrEqual(
            SettingsRowViewMetrics.controlMinWidth,
            SettingsRowViewMetrics.controlMaxWidth
        )
    }

    func testLabelColumnKeepsAFloorSoNarrowRowsStayReadable() {
        XCTAssertGreaterThanOrEqual(SettingsRowViewMetrics.labelWidth, 190)
    }

    // MARK: - Layout

    /// The regression itself. A fixed label column produces the same height at
    /// every pane width; a flexible one re-wraps and gets shorter as the pane
    /// grows. `UsageDashboardView`'s settings mode hands panes ~772pt at the
    /// default window size and more when the user resizes.
    func testLongDetailReflowsIntoTheExtraWidthOfAWiderPane() {
        let narrow = measuredHeight(of: longDetailRow, width: 560)
        let wide = measuredHeight(of: longDetailRow, width: 900)

        XCTAssertLessThan(
            wide,
            narrow,
            "the detail column ignored the extra pane width — it is still fixed"
        )
    }

    /// A toggle must not reserve the same slot as a 260pt text field; the space
    /// it does not need belongs to the label.
    func testCompactControlReservesLessThanAWideOne() {
        let toggleWidth = measuredWidth(of: SettingsRowView(title: "Pin") {
            Toggle("", isOn: .constant(true)).labelsHidden()
        })
        let fieldWidth = measuredWidth(of: SettingsRowView(title: "Pin") {
            Color.clear.frame(width: 260, height: 20)
        })

        XCTAssertLessThan(
            toggleWidth,
            fieldWidth,
            "every control still reserves one constant width"
        )
    }

    /// The 260pt provider key field overflowed the old 240pt slot. The row's
    /// ideal width has to leave room for the control it was actually given.
    func testWideControlIsNotClipped() {
        let width = measuredWidth(of: SettingsRowView(title: "Pin") {
            Color.clear.frame(width: 260, height: 20)
        })

        XCTAssertGreaterThanOrEqual(width, SettingsRowViewMetrics.labelWidth + 260)
    }

    // MARK: - Copy

    func testMenuBarLayoutCopyKeepsTheAccountItemLimit() {
        let copy = GeneralSettingsCopy.menuBarLayout(itemLimit: 4)

        XCTAssertTrue(copy.contains("4"), copy)
        XCTAssertTrue(copy.lowercased().contains("right-click"), copy)
    }

    func testMenuBarShowsCopyKeepsPinExclusivity() {
        let copy = GeneralSettingsCopy.menuBarShows.lowercased()

        XCTAssertTrue(copy.contains("focus following"), copy)
        XCTAssertTrue(copy.contains("rotation"), copy)
    }

    func testRotationCopyKeepsThePopoverPause() {
        let copy = GeneralSettingsCopy.rotateProviders.lowercased()

        XCTAssertTrue(copy.contains("pauses while the popover is open"), copy)
        XCTAssertTrue(copy.contains("critical"), copy)
    }

    func testFollowFocusedAppCopyKeepsPrivacyPostureAndExclusivity() {
        let copy = GeneralSettingsCopy.followFocusedApp.lowercased()

        XCTAssertTrue(copy.contains("bundle identifier"), copy)
        XCTAssertTrue(copy.contains("accessibility"), copy)
        XCTAssertTrue(copy.contains("pin"), copy)
        XCTAssertTrue(copy.contains("rotation"), copy)
    }

    func testRefreshIntervalCopyKeepsTheAdaptiveBounds() {
        let copy = GeneralSettingsCopy.autoRefreshInterval

        XCTAssertTrue(copy.contains("1"), copy)
        XCTAssertTrue(copy.contains("30"), copy)
    }

    /// Widening the label column is only half the fix: the copy that filled it
    /// has to come down to one or two sentences per row.
    func testEveryTightenedDetailStaysWithinTwoSentences() {
        let copy = [
            "autoRefreshInterval": GeneralSettingsCopy.autoRefreshInterval,
            "menuBarLayout": GeneralSettingsCopy.menuBarLayout(itemLimit: 4),
            "menuBarShows": GeneralSettingsCopy.menuBarShows,
            "rotateProviders": GeneralSettingsCopy.rotateProviders,
            "followFocusedApp": GeneralSettingsCopy.followFocusedApp,
        ]

        for (name, text) in copy {
            let sentences = text.split(separator: ".").filter {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
            XCTAssertLessThanOrEqual(sentences.count, 2, "\(name) is still \(sentences.count) sentences")
            XCTAssertFalse(text.isEmpty, name)
        }
    }

    // MARK: - Helpers

    /// A detail long enough that the wrap point moves between 560pt and 900pt.
    private var longDetailRow: some View {
        SettingsRowView(
            title: "Follow focused app",
            detail: GeneralSettingsCopy.followFocusedApp
        ) {
            Toggle("", isOn: .constant(false)).labelsHidden()
        }
    }

    private func measuredHeight(of view: some View, width: CGFloat) -> CGFloat {
        let hostingView = NSHostingView(rootView: view.frame(width: width))
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize.height
    }

    /// The row's *ideal* width — what the two columns ask for before a pane
    /// hands them anything. Short titles keep the label at its floor so the
    /// difference between two measurements is entirely the control column.
    private func measuredWidth(of view: some View) -> CGFloat {
        let hostingView = NSHostingView(rootView: view)
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize.width
    }
}
