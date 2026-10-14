import MeterBarShared
import XCTest

final class MuseCodeReadinessTests: XCTestCase {
    func testEachSignInStateUsesItsAuthoredSentence() {
        let cases: [(MuseCodeCredentialProbe, String)] = [
            (.notSignedIn, MuseCodeCopy.notSignedIn),
            (.needsConnect, MuseCodeCopy.needsConnect),
            (.needsKeychainAccess, MuseCodeCopy.needsKeychainAccess),
            (.rejectedToken, MuseCodeCopy.rejectedToken),
            (.noSubscription, MuseCodeCopy.noSubscription),
            (.unreadable, MuseCodeCopy.unreadable),
        ]
        for (probe, sentence) in cases {
            let report = ProviderReadinessEvaluator.museCode(MuseCodeReadinessInput(probe: probe))
            let details = report.checks.map(\.detail).joined(separator: "\n")
            XCTAssertTrue(details.contains(sentence), "\(probe) missing its sentence")
            XCTAssertFalse(details.contains("dca:"))
            XCTAssertFalse(details.contains("auth.json"))
            XCTAssertFalse(details.contains("@"))
        }
    }

    func testDisabledProviderDoesNotClaimAReadableSignIn() {
        let report = ProviderReadinessEvaluator.museCode(MuseCodeReadinessInput(probe: .disabled))
        XCTAssertEqual(report.provider, .museCode)
        XCTAssertTrue(report.checks.contains { $0.detail == "Muse Code is off." })
        XCTAssertFalse(report.checks.contains { $0.level == .pass && $0.id == ReadinessCheckID.auth })
    }

    func testReadySignInCanReadUsage() {
        let report = ProviderReadinessEvaluator.museCode(MuseCodeReadinessInput(probe: .ready))
        XCTAssertTrue(report.checks.contains { $0.id == ReadinessCheckID.data && $0.level == .pass })
        XCTAssertTrue(report.checks.contains { $0.detail == "Muse Code sign-in is readable." })
    }
}
