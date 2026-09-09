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

    /// Every provider whose mark ships as an SVG must actually resolve to that
    /// SVG.
    ///
    /// `ProviderLogoView` falls back to an SF Symbol when the asset cannot be
    /// found, and the fallback for Codex is `terminal.fill` — a perfectly
    /// plausible-looking glyph that is not the Codex mark. That failure is
    /// silent by construction: the view renders, nothing throws, and a share
    /// card exported from a preview or a test carries the wrong logo. The only
    /// way to catch it is to assert the lookup itself.
    func testEveryProviderLogoResolvesToItsRealAsset() {
        for service in ServiceType.allCases {
            let kind = ProviderLogoKind.forService(service)
            guard let resourceName = kind.resourceName else { continue }

            XCTAssertNotNil(
                ProviderLogoImageCache.image(named: resourceName),
                "\(service) falls back to the SF Symbol \(kind.fallbackSystemName) instead of \(resourceName)"
            )
        }
    }

    /// Cursor Ultra's Grok Bot pool is branded Grok and titled "Grok Bot", so a
    /// gallery shows it beside a real Grok account — two cards, same mark,
    /// near-identical names, routinely opposite statuses. Posted standalone,
    /// nothing on the card says which Grok is out, so a sub-pool card names the
    /// account it is carved out of, in the masthead and in the caption.
    func testSubPoolCardNamesTheAccountItIsCarvedOutOf() {
        var pool = Self.snapshot(id: "cursor.grokbot", title: "Grok Bot", service: .cursor)
        pool.cardRole = .subPool
        pool.logoKindOverride = .grok

        let content = SocialLimitsCardContent(snapshot: pool)

        XCTAssertEqual(content.providerQualifier, "Cursor")
        XCTAssertTrue(
            content.shareCaption.contains("Grok Bot on Cursor"),
            "a posted caption must say which account the pool belongs to"
        )
    }

    /// An ordinary provider card names its own service already; qualifying it
    /// would say the same thing twice.
    func testOrdinaryProviderCardCarriesNoQualifier() {
        let account = Self.snapshot(id: "grok", title: "Grok", service: .grok)

        XCTAssertNil(SocialLimitsCardContent(snapshot: account).providerQualifier)
    }

    private static func snapshot(id: String, title: String, service: ServiceType) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id,
            title: title,
            service: service,
            updatedAt: Date(timeIntervalSince1970: 0),
            limits: [
                SnapshotLimit(
                    id: "weekly",
                    kind: .weekly,
                    title: "Weekly",
                    usageLimit: UsageLimit(
                        used: 23,
                        total: 100,
                        resetTime: Date(timeIntervalSince1970: 500_000),
                        windowSeconds: 604_800
                    )
                ),
            ],
            emptyDetail: "",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil
        )
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
