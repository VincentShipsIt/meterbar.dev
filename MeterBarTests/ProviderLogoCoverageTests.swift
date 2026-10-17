import MeterBarShared
import XCTest
@testable import MeterBar

/// Every provider shows its official brand mark, never a stand-in SF Symbol.
///
/// An SF Symbol such as `arrow.triangle.2.circlepath` or `sparkles` renders fine
/// and reads as a different company's logo, so the only way to keep it out is to
/// assert that each provider's lookup resolves to a bundled SVG.
final class ProviderLogoCoverageTests: XCTestCase {
    private var brandedKinds: [ProviderLogoKind] {
        [
            .codex, .claude, .cursor, .openai, .openRouter, .grok,
            .kimiCode, .zaiCodingPlan, .githubCopilot, .museCode, .claudePlatform,
        ]
    }

    func testEveryProviderKindHasABundledResourceName() {
        for kind in brandedKinds {
            XCTAssertNotNil(kind.resourceName, "\(kind) has no bundled SVG and would fall back to an SF Symbol")
        }
    }

    func testEveryProviderKindResolvesItsBundledSVG() {
        for kind in brandedKinds {
            guard let name = kind.resourceName else { continue }
            XCTAssertNotNil(ProviderLogoImageCache.image(named: name), "\(name).svg is missing from the app bundle")
        }
    }

    func testEveryServiceTypeMapsToAPopoverLogoAndAWidgetImageset() throws {
        let widgetAssets = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MeterBarWidget/Assets.xcassets")
        for service in ServiceType.allCases {
            XCTAssertNotNil(
                ProviderLogoKind.forService(service).resourceName,
                "\(service) has no popover logo"
            )
            let imageset = widgetAssets.appendingPathComponent("\(service.assetName).imageset/Contents.json")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: imageset.path),
                "\(service) has no widget imageset named \(service.assetName)"
            )
        }
    }

    func testEveryApiProviderMapsToABundledLogo() {
        for provider in ApiProvider.allCases {
            XCTAssertNotNil(
                ProviderLogoKind.forApiProvider(provider).resourceName,
                "\(provider) has no bundled logo"
            )
        }
    }

    func testDistinctProvidersNeverShareOneMark() {
        let names = ServiceType.allCases.compactMap { ProviderLogoKind.forService($0).resourceName }
        XCTAssertEqual(Set(names).count, names.count, "two providers resolve to the same logo file")
    }
}
