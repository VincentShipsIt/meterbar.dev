import SwiftUI

enum MeterBarTheme {
    static let anthropicDark = Color(red: 20 / 255, green: 20 / 255, blue: 19 / 255)
    static let anthropicLight = Color(red: 250 / 255, green: 249 / 255, blue: 245 / 255)
    static let claudeAccent = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
    static let warning = Color(red: 234 / 255, green: 179 / 255, blue: 8 / 255)
    static let toolbarIconForeground = Color.white.opacity(0.92)
    static let toolbarIconBackground = Color(red: 32 / 255, green: 35 / 255, blue: 42 / 255)
    static let toolbarIconBorder = Color.white.opacity(0.14)
}

enum LucideSymbol {
    case panelRight
    case refreshCw
    case search

    fileprivate func path() -> Path {
        var path = Path()

        switch self {
        case .panelRight:
            path.addRoundedRect(in: CGRect(x: 3, y: 3, width: 18, height: 18), cornerSize: CGSize(width: 2, height: 2))
            path.move(to: CGPoint(x: 15, y: 3))
            path.addLine(to: CGPoint(x: 15, y: 21))

        case .refreshCw:
            path.move(to: CGPoint(x: 21, y: 12))
            path.addCurve(to: CGPoint(x: 12, y: 3), control1: CGPoint(x: 21, y: 7.03), control2: CGPoint(x: 16.97, y: 3))
            path.addCurve(to: CGPoint(x: 5.64, y: 5.64), control1: CGPoint(x: 9.52, y: 3), control2: CGPoint(x: 7.27, y: 4.01))
            path.move(to: CGPoint(x: 3, y: 8))
            path.addLine(to: CGPoint(x: 3, y: 3))
            path.move(to: CGPoint(x: 3, y: 8))
            path.addLine(to: CGPoint(x: 8, y: 8))
            path.move(to: CGPoint(x: 3, y: 12))
            path.addCurve(to: CGPoint(x: 12, y: 21), control1: CGPoint(x: 3, y: 16.97), control2: CGPoint(x: 7.03, y: 21))
            path.addCurve(to: CGPoint(x: 18.36, y: 18.36), control1: CGPoint(x: 14.48, y: 21), control2: CGPoint(x: 16.73, y: 19.99))
            path.move(to: CGPoint(x: 21, y: 16))
            path.addLine(to: CGPoint(x: 21, y: 21))
            path.move(to: CGPoint(x: 21, y: 16))
            path.addLine(to: CGPoint(x: 16, y: 16))

        case .search:
            path.addEllipse(in: CGRect(x: 4, y: 4, width: 11, height: 11))
            path.move(to: CGPoint(x: 14, y: 14))
            path.addLine(to: CGPoint(x: 20, y: 20))
        }

        return path
    }
}

struct LucideIcon: View {
    let symbol: LucideSymbol
    let size: CGFloat
    let lineWidth: CGFloat

    init(_ symbol: LucideSymbol, size: CGFloat = 18, lineWidth: CGFloat = 2.25) {
        self.symbol = symbol
        self.size = size
        self.lineWidth = lineWidth
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width, proxy.size.height) / 24
            let xOffset = (proxy.size.width - (24 * scale)) / 2
            let yOffset = (proxy.size.height - (24 * scale)) / 2
            let transform = CGAffineTransform(translationX: xOffset, y: yOffset)
                .scaledBy(x: scale, y: scale)

            symbol.path()
                .applying(transform)
                .stroke(style: StrokeStyle(lineWidth: lineWidth * scale, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

struct RefreshIconButton: View {
    let title: String?
    let help: String
    let isDisabled: Bool
    let action: () -> Void

    @State private var rotation: Double = 0

    init(
        title: String? = nil,
        help: String = "Refresh",
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.help = help
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button {
            guard !isDisabled else { return }
            withAnimation(.easeInOut(duration: 0.55)) {
                rotation += 360
            }
            action()
        } label: {
            HStack(spacing: title == nil ? 0 : 7) {
                LucideIcon(.refreshCw, size: 17, lineWidth: 2.35)
                    .rotationEffect(.degrees(rotation))
                    .frame(width: 18, height: 18)

                if let title {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
            }
            .foregroundColor(MeterBarTheme.toolbarIconForeground)
            .frame(width: title == nil ? 32 : nil, height: 32)
            .padding(.horizontal, title == nil ? 0 : 10)
            .background(MeterBarTheme.toolbarIconBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(MeterBarTheme.toolbarIconBorder, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .opacity(isDisabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
    }
}
