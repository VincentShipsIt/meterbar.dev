import Foundation
@testable import MeterBar
import XCTest

final class SparkleUpdateTests: XCTestCase {
    #if !canImport(Sparkle)
    func testFallbackConfigurationExplainsUpdatesAreUnavailable() {
        let controller = SoftwareUpdateController()

        XCTAssertEqual(controller.configurationError, "Software updates are unavailable in this build.")
        XCTAssertFalse(controller.canCheckForUpdates)
    }
    #endif

    func testKeyValidatorRejectsUnsubstitutedBuildVariable() {
        // Debug and PR-gate builds never substitute the build setting, so the
        // literal variable is exactly what ships in their Info.plist.
        XCTAssertFalse(SoftwareUpdateController.isUsableEDPublicKey("$(SPARKLE_PUBLIC_ED_KEY)"))
        XCTAssertFalse(SoftwareUpdateController.isUsableEDPublicKey("${SPARKLE_PUBLIC_ED_KEY}"))
    }

    func testKeyValidatorRejectsEmptyAndMalformedKeys() {
        XCTAssertFalse(SoftwareUpdateController.isUsableEDPublicKey(""))
        XCTAssertFalse(SoftwareUpdateController.isUsableEDPublicKey("   "))
        XCTAssertFalse(SoftwareUpdateController.isUsableEDPublicKey("not base64!!"))
        // Valid base64 of the wrong length is not an Ed25519 public key.
        let shortKey = Data(repeating: 7, count: 16).base64EncodedString()
        XCTAssertFalse(SoftwareUpdateController.isUsableEDPublicKey(shortKey))
    }

    func testKeyValidatorAcceptsWellFormedEd25519Key() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        XCTAssertTrue(SoftwareUpdateController.isUsableEDPublicKey(key))
        XCTAssertTrue(SoftwareUpdateController.isUsableEDPublicKey(" \(key) "))
    }

    func testCheckedInConfigurationRequiresAutomaticCheckConsent() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = repositoryRoot.appendingPathComponent("MeterBar/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertEqual(
            plist["SUFeedURL"] as? String,
            "https://github.com/VincentShipsIt/meterbar.dev/releases/latest/download/appcast.xml"
        )
        XCTAssertEqual(plist["SUPublicEDKey"] as? String, "$(SPARKLE_PUBLIC_ED_KEY)")
    }

    func testVersionComparatorOffers171To170() {
        XCTAssertEqual("1.7.1".compare("1.7.0", options: .numeric), .orderedDescending)
        XCTAssertEqual("1.7.0".compare("1.7.1", options: .numeric), .orderedAscending)
        XCTAssertEqual("1.7.1".compare("1.7.1", options: .numeric), .orderedSame)
    }

    func testAppcastContractCarriesSignedReleaseArchive() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <title>Version 1.7.1</title>
              <sparkle:version>1.7.1</sparkle:version>
              <sparkle:shortVersionString>1.7.1</sparkle:shortVersionString>
              <enclosure
                url="https://github.com/VincentShipsIt/meterbar.dev/releases/download/v1.7.1/MeterBar-v1.7.1.zip"
                sparkle:edSignature="signed-update"
                length="1234"
                type="application/octet-stream" />
            </item>
          </channel>
        </rss>
        """

        let document = try XMLDocument(xmlString: xml)
        let enclosure = try XCTUnwrap(document.nodes(forXPath: "/rss/channel/item/enclosure").first as? XMLElement)
        let item = try XCTUnwrap(document.nodes(forXPath: "/rss/channel/item").first as? XMLElement)

        XCTAssertEqual(enclosure.attribute(forName: "url")?.stringValue?.hasSuffix("MeterBar-v1.7.1.zip"), true)
        let namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
        XCTAssertEqual(item.elements(forLocalName: "version", uri: namespace).first?.stringValue, "1.7.1")
        XCTAssertEqual(item.elements(forLocalName: "shortVersionString", uri: namespace).first?.stringValue, "1.7.1")
        XCTAssertFalse(try XCTUnwrap(enclosure.attributes?.first { $0.localName == "edSignature" }).stringValue?.isEmpty ?? true)

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meterbar-appcast-\(UUID().uuidString).xml")
        try xml.write(to: temporaryURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let verifier = repositoryRoot.appendingPathComponent("scripts/verify-appcast.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            verifier.path,
            temporaryURL.path,
            "1.7.1",
            "MeterBar-v1.7.1.zip",
            "https://github.com/VincentShipsIt/meterbar.dev/releases/download/v1.7.1/"
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Update channel

    private func makeIsolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "meterbar-channel-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    func testChannelDefaultsToStableWhenUnsetOrInvalid() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(SoftwareUpdateController.loadChannel(from: defaults), .stable)

        defaults.set("not-a-channel", forKey: SoftwareUpdateController.channelStorageKey)
        XCTAssertEqual(SoftwareUpdateController.loadChannel(from: defaults), .stable)
    }

    func testChannelPersistenceRoundTrips() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SoftwareUpdateController.persistChannel(.nightly, to: defaults)
        XCTAssertEqual(
            defaults.string(forKey: SoftwareUpdateController.channelStorageKey),
            UpdateChannel.nightly.rawValue
        )
        XCTAssertEqual(SoftwareUpdateController.loadChannel(from: defaults), .nightly)

        SoftwareUpdateController.persistChannel(.stable, to: defaults)
        XCTAssertEqual(SoftwareUpdateController.loadChannel(from: defaults), .stable)
    }

    func testStableChannelFallsBackToInfoPlistFeed() {
        // nil tells Sparkle to use the Info.plist SUFeedURL (the stable feed).
        XCTAssertNil(SoftwareUpdateController.resolvedFeedURLString(for: .stable))
    }

    func testNightlyChannelResolvesToRollingNightlyFeed() throws {
        let feed = try XCTUnwrap(SoftwareUpdateController.resolvedFeedURLString(for: .nightly))
        XCTAssertEqual(feed, SoftwareUpdateController.nightlyFeedURLString)
        XCTAssertTrue(feed.hasPrefix("https://"))
        // Fixed `nightly` tag path — never `/latest/`, which excludes prereleases.
        XCTAssertTrue(feed.contains("/releases/download/nightly/"))
        XCTAssertTrue(feed.hasSuffix("/appcast-nightly.xml"))
        XCTAssertNotNil(URL(string: feed))
    }

    // MARK: - Nightly version ordering

    // Nightly CFBundleVersion is `<latest-stable>.<commits>` (e.g. 1.7.1.5) so
    // Sparkle's numeric comparator ranks a newer nightly above an older one,
    // above the last stable, and BELOW the next stable — letting a switch back
    // to Stable auto-update cleanly once the next tagged release ships.
    func testNightlyBuildOutranksBaseStable() {
        XCTAssertEqual("1.7.1.5".compare("1.7.1", options: .numeric), .orderedDescending)
    }

    func testLaterNightlyOutranksEarlierNightly() {
        XCTAssertEqual("1.7.1.6".compare("1.7.1.5", options: .numeric), .orderedDescending)
    }

    func testNextStableOutranksNightly() {
        XCTAssertEqual("1.7.2".compare("1.7.1.5", options: .numeric), .orderedDescending)
        // Even a high nightly build number cannot beat the next stable minor.
        XCTAssertEqual("1.7.2".compare("1.7.1.9999", options: .numeric), .orderedDescending)
    }
}
