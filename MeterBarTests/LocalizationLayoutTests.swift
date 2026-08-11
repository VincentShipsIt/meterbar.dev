import AppKit
import MeterBarShared
import SwiftUI
import XCTest
@testable import MeterBar

/// Double-length and RTL smoke coverage for the first localized surfaces.
/// Xcode's pseudolanguages remain the visual QA gate; these tests make the
/// narrow app geometry and the flexible settings-row behavior regressible.
@MainActor
final class LocalizationLayoutTests: XCTestCase {
    func testPseudoLocalizedQuotaRowRendersAtPopoverWidthInBothDirections() {
        let limit = SnapshotLimit(
            id: "weekly",
            kind: .weekly,
            title: pseudo("Weekly usage limit"),
            usageLimit: UsageLimit(
                used: 72,
                total: 100,
                resetTime: Date().addingTimeInterval(3_660),
                windowSeconds: 604_800,
                isEstimated: true
            )
        )

        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let view = LimitRow(limit: limit, accentColor: .blue, density: .compact)
                .environment(\.locale, Locale(identifier: direction == .leftToRight ? "en_XA" : "ar_XB"))
                .environment(\.layoutDirection, direction)
                .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
                .frame(width: 240)
            let host = NSHostingView(rootView: view)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
            XCTAssertLessThan(host.fittingSize.height, 180, "quota row expanded beyond the popover budget")
        }
    }

    func testPseudoLocalizedSettingsRowStillUsesAvailableWidth() {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let narrow = settingsRowHeight(width: 560, direction: direction)
            let wide = settingsRowHeight(width: 900, direction: direction)
            XCTAssertLessThan(wide, narrow, "pseudo-localized settings copy did not reflow for \(direction)")
        }
    }

    private func settingsRowHeight(width: CGFloat, direction: LayoutDirection) -> CGFloat {
        let view = SettingsRowView(
            title: pseudo("Follow focused application"),
            detail: pseudo(
                "MeterBar matches the frontmost application's bundle identifier locally and never reads window text."
            )
        ) {
            Toggle("", isOn: .constant(false)).labelsHidden()
        }
        .environment(\.locale, Locale(identifier: direction == .leftToRight ? "en_XA" : "ar_XB"))
        .environment(\.layoutDirection, direction)
        .frame(width: width)

        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private func pseudo(_ source: String) -> String {
        let expanded = source.map { character -> String in
            switch character {
            case "a": return "àà"
            case "e": return "ëë"
            case "i": return "ïï"
            case "o": return "ôô"
            case "u": return "üü"
            case "A": return "ÀÀ"
            case "E": return "ËË"
            case "I": return "ÏÏ"
            case "O": return "ÔÔ"
            case "U": return "ÜÜ"
            default: return String(character)
            }
        }.joined()
        return "[!! \(expanded) !!]"
    }
}
