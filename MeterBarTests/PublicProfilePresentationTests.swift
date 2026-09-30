import XCTest
@testable import MeterBar

final class PublicProfilePresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOffShowsNothingUnlessARemovalIsStillOwed() {
        XCTAssertNil(PublicProfilePresentation.statusText(status: .off, lastPublishedAt: nil, pendingDeletions: 0))
        XCTAssertNotNil(PublicProfilePresentation.statusText(status: .off, lastPublishedAt: nil, pendingDeletions: 1))
    }

    func testLiveStatusNamesHowFreshThePageIs() {
        let text = PublicProfilePresentation.statusText(
            status: .live,
            lastPublishedAt: now.addingTimeInterval(-300),
            pendingDeletions: 0,
            now: now
        )
        XCTAssertTrue(text?.hasPrefix("Live · updated ") ?? false, text ?? "nil")
    }

    func testErrorStatusShowsTheMessage() {
        XCTAssertEqual(
            PublicProfilePresentation.statusText(status: .error("boom"), lastPublishedAt: nil, pendingDeletions: 0),
            "boom"
        )
    }

    func testXShareLinkCarriesOnlyTheProfileURL() throws {
        let profile = URL(string: "https://meterbar.dev/u/abcdefghjk")!

        let url = try XCTUnwrap(PublicProfilePresentation.xShareURL(profileURL: profile))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        XCTAssertEqual(url.host, "x.com")
        XCTAssertEqual(items.first { $0.name == "url" }?.value, profile.absoluteString)
        XCTAssertEqual(Set(items.map(\.name)), ["text", "url"])
    }

    /// The copy the toggle sits under is the consent: it has to say what is
    /// sent and what never is.
    func testConsentCopyStatesWhatIsAndIsNeverPublished() {
        XCTAssertTrue(PublicProfilePresentation.summary(isEnabled: false).contains("nothing until you do"))
        XCTAssertTrue(PublicProfilePresentation.summary(isEnabled: true).contains("delete the published copy"))
        for word in ["email", "account names", "folders", "credentials"] {
            XCTAssertTrue(PublicProfilePresentation.neverPublished.contains(word), word)
        }
    }
}
