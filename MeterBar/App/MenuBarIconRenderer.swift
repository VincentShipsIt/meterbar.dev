import AppKit

/// Menu-bar image drawing extracted from `MeterBarApp.swift` (C1 split).
///
/// Pure move: the meter icon keeps its `NSImage(size:flipped:)` drawing block
/// and the status dot keeps its `lockFocus` idiom, because the two produce
/// different template/non-template images and the dot is rendered per menu item.
enum MenuBarIconRenderer {
    static let iconSize = NSSize(width: 18, height: 18)
    static let statusDotSize = NSSize(width: 10, height: 10)

    /// The three-bar meter shown as the status item's image. Template so macOS
    /// tints it for light/dark menu bars.
    static func meterIcon() -> NSImage {
        let image = NSImage(size: iconSize, flipped: false) { rect in
            let barHeight: CGFloat = 3
            let barSpacing: CGFloat = 2
            let cornerRadius: CGFloat = 1.5

            // Three bars with different widths (like progress indicators)
            let barWidths: [CGFloat] = [0.35, 0.55, 0.85] // 35%, 55%, 85%
            let totalBarsHeight = (barHeight * 3) + (barSpacing * 2)
            let startY = (rect.height - totalBarsHeight) / 2

            for (index, fillPercent) in barWidths.enumerated() {
                let y = startY + CGFloat(index) * (barHeight + barSpacing)
                let barWidth = rect.width * fillPercent

                let barRect = NSRect(x: 0, y: y, width: barWidth, height: barHeight)
                let path = NSBezierPath(roundedRect: barRect, xRadius: cornerRadius, yRadius: cornerRadius)
                NSColor.black.setFill()
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// A filled dot used as the leading image of provider status menu items.
    /// Explicitly non-template so the severity colour survives menu tinting.
    static func statusDot(for indicator: ProviderStatusIndicator) -> NSImage {
        let image = NSImage(size: statusDotSize)
        image.lockFocus()
        statusDotColor(for: indicator).setFill()
        NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 6, height: 6)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    static func statusDotColor(for indicator: ProviderStatusIndicator) -> NSColor {
        switch indicator {
        case .none:
            return .systemGreen
        case .minor, .maintenance:
            return .systemOrange
        case .major, .critical:
            return .systemRed
        case .unknown:
            return .tertiaryLabelColor
        }
    }
}
