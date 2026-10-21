import AppKit
import MeterBarShared
import SwiftUI
import XCTest
@testable import MeterBar

@MainActor
final class ProviderCardHeaderLayoutTests: XCTestCase {
    func testRenderedTitleAndSubtitleAlignInLightAppearance() throws {
        try assertRenderedAlignment(scheme: .light)
    }

    func testRenderedTitleAndSubtitleAlignInDarkAppearance() throws {
        try assertRenderedAlignment(scheme: .dark)
    }

    private func assertRenderedAlignment(scheme: ColorScheme) throws {
        var snapshot = ProviderSnapshot(
            id: "header-alignment", title: "HHHH", service: .codexCli,
            updatedAt: nil, limits: [], emptyDetail: "", extraUsage: nil,
            resetCreditsAvailable: nil, accountID: nil
        )
        // Identical glyphs isolate layout from different letter bearings.
        snapshot.freshnessNote = "HHHH"
        for width: CGFloat in [300, 340] {
            let renderer = ImageRenderer(content: ProviderCardHeader(snapshot: snapshot)
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.colorScheme, scheme))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let bands = textBands(in: bitmap)
            XCTAssertEqual(bands.count, 2, "Expected two rendered text lines at width \(width)")
            guard bands.count == 2 else { continue }
            XCTAssertGreaterThan(bands[0], 0, "Provider title must leave room for its logo")
            XCTAssertEqual(Double(bands[0]), Double(bands[1]), accuracy: 2,
                           "Rendered text leading edges differ at width \(width)")
        }
    }

    /// Transparent pixels and the colored provider mark are excluded. Each
    /// contiguous band of neutral ink is one of the two actual text lines.
    private func textBands(in bitmap: NSBitmapImageRep) -> [Int] {
        var bands: [Int] = []
        var inBand = false
        for y in 0..<bitmap.pixelsHigh {
            let left = (0..<bitmap.pixelsWide).first { x in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return color.alphaComponent > 0.2
                    && abs(color.redComponent - color.greenComponent) < 0.02
                    && abs(color.greenComponent - color.blueComponent) < 0.02
            }
            if let left {
                if inBand {
                    bands[bands.count - 1] = min(bands[bands.count - 1], left)
                } else {
                    bands.append(left)
                }
                inBand = true
            } else {
                inBand = false
            }
        }
        return bands
    }
}
