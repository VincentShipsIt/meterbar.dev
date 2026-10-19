import MeterBarShared
import XCTest
@testable import MeterBar

/// A connected Muse Code row must not keep offering "Connect Muse Code".
final class MuseCodeSettingsSectionTests: XCTestCase {
    func testReadySignInOffersAQuietReconnect() {
        XCTAssertEqual(MuseCodeSettingsSection.connectButtonTitle(for: .ready), "Reconnect")
        XCTAssertFalse(MuseCodeSettingsSection.connectIsProminent(for: .ready))
    }

    func testEveryOtherStateKeepsTheProminentConnect() {
        let others: [MuseCodeCredentialProbe?] = [
            nil, .disabled, .notSignedIn, .rejectedToken, .needsConnect,
            .needsKeychainAccess, .noSubscription, .unreadable
        ]
        for probe in others {
            XCTAssertEqual(MuseCodeSettingsSection.connectButtonTitle(for: probe), "Connect Muse Code")
            XCTAssertTrue(MuseCodeSettingsSection.connectIsProminent(for: probe))
        }
    }
}
