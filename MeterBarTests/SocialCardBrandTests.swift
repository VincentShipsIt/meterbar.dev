import MeterBarShared
import SwiftUI
import XCTest

@testable import MeterBar

/// The share cards used to head themselves with SF Symbols that appear nowhere
/// else in the product — `chart.bar.xaxis` in a white circle on the receipt,
/// `gauge.with.needle.fill` on the limits card — and to spend two unrelated
/// color ramps between them. These tests pin both cards to the app icon, which
/// is the one thing a posted screenshot has to be recognizable as.
final class SocialCardBrandTests: XCTestCase {
    /// The mark is redrawn in SwiftUI rather than loaded from `AppIcon`, so
    /// nothing but a test stops it drifting away from the icon it is copying.
    /// These are `docs/logo.svg`'s three bars: 96, 176 and 272 wide in a 320pt
    /// track, in the icon's green, amber and red.
    func testBrandMarkDrawsTheAppIconsThreeBars() {
        XCTAssertEqual(MeterBarBrandMark.bars.map(\.fill), [0.30, 0.55, 0.85])
        XCTAssertEqual(
            MeterBarBrandMark.bars.map(\.color),
            [MeterBarBrand.green, MeterBarBrand.amber, MeterBarBrand.red]
        )
    }

    /// Severity on a card is the icon's own ramp, not a second palette that
    /// happens to also mean "bad". Every band must be spoken for — an
    /// unmapped band would silently fall back to the no-data gray.
    func testCardSeverityRampIsTheIconRamp() {
        XCTAssertEqual(SocialCardPalette.accent(for: .healthy), MeterBarBrand.green)
        XCTAssertEqual(SocialCardPalette.accent(for: .tight), MeterBarBrand.amber)
        XCTAssertEqual(SocialCardPalette.accent(for: .critical), MeterBarBrand.red)
        XCTAssertEqual(SocialCardPalette.accent(for: .exhausted), MeterBarBrand.deepRed)

        let noData = SocialCardPalette.accent(for: nil)
        for band in [QuotaBand.healthy, .tight, .critical, .exhausted] {
            XCTAssertNotEqual(
                SocialCardPalette.accent(for: band),
                noData,
                "\(band) has no accent of its own and reads as 'no data'."
            )
        }
    }

    /// The receipt reports no severity, so it takes a fixed brand accent rather
    /// than borrowing a band color that would imply one.
    func testReceiptAccentIsBrandAmberNotABandColor() {
        XCTAssertEqual(SocialCardPalette.receiptAccent, MeterBarBrand.amber)
    }

    /// The limits card puts the provider's mark beside MeterBar's, which only
    /// works if the content carries it — and Cursor's Grok Bot pool proves the
    /// card must follow `logoKind` (the pool is branded Grok) rather than the
    /// service it borrows its data from.
    func testLimitsContentCarriesTheProvidersOwnLogo() {
        var snapshot = ProviderSnapshot(
            id: "cursor.grokbot",
            title: "Grok Bot",
            service: .cursor,
            updatedAt: Date(timeIntervalSince1970: 0),
            limits: [],
            emptyDetail: "",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil
        )
        snapshot.logoKindOverride = .grok

        XCTAssertEqual(SocialLimitsCardContent(snapshot: snapshot).providerLogo, .grok)
    }

    /// The gallery's placeholder tile speaks for no provider, so it must not
    /// borrow one's mark.
    func testPlaceholderLimitsCardHasNoProviderLogo() {
        let content = SocialLimitsCardContent(
            providerName: SocialShareCardContent.appName,
            updatedText: "No data",
            headline: nil,
            rows: []
        )

        XCTAssertNil(content.providerLogo)
    }
}
