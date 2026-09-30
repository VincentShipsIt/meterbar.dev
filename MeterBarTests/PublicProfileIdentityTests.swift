import XCTest
@testable import MeterBar

final class PublicProfileIdentityTests: XCTestCase {
    func testMintedSlugIsTenCrockfordCharacters() {
        for _ in 0..<50 {
            let identity = PublicProfileIdentity.mint()
            XCTAssertTrue(PublicProfileIdentity.isValidSlug(identity.slug), identity.slug)
            XCTAssertEqual(identity.slug.count, PublicProfileIdentity.slugLength)
        }
    }

    func testSlugsAreNotReusedAndCarryNoAmbiguousLetters() {
        let slugs = (0..<500).map { _ in PublicProfileIdentity.mint().slug }
        XCTAssertEqual(Set(slugs).count, slugs.count)
        XCTAssertTrue(slugs.allSatisfy { slug in !slug.contains { "ilou".contains($0) } })
    }

    func testPublishKeyIsBase64URLOfThirtyTwoBytes() {
        let key = PublicProfileIdentity.mint().publishKey
        XCTAssertEqual(key.count, 43)
        XCTAssertNil(key.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testKeyIsIndependentOfSlug() {
        let identity = PublicProfileIdentity.mint()
        XCTAssertFalse(identity.publishKey.contains(identity.slug))
    }

    func testSlugValidationRejectsWrongLengthAndCharacters() {
        XCTAssertFalse(PublicProfileIdentity.isValidSlug(""))
        XCTAssertFalse(PublicProfileIdentity.isValidSlug("abc"))
        XCTAssertFalse(PublicProfileIdentity.isValidSlug("ABCDEFGHJK"))
        XCTAssertFalse(PublicProfileIdentity.isValidSlug("../../etc/x"))
        XCTAssertFalse(PublicProfileIdentity.isValidSlug("0123456789a"))
        XCTAssertTrue(PublicProfileIdentity.isValidSlug("0123456789"))
    }

    func testURLsUseTheSlugOnly() {
        let base = URL(string: "https://meterbar.dev")!
        XCTAssertEqual(
            PublicProfileIdentity.profileURL(slug: "abcdefghjk", base: base).absoluteString,
            "https://meterbar.dev/u/abcdefghjk"
        )
        XCTAssertEqual(
            PublicProfileEndpoint.apiURL(slug: "abcdefghjk", base: base).absoluteString,
            "https://meterbar.dev/api/profile/abcdefghjk"
        )
    }

    func testReleaseEndpointIsMeterbarDev() {
        XCTAssertEqual(PublicProfileEndpoint.defaultBaseURL.absoluteString, "https://meterbar.dev")
    }
}
