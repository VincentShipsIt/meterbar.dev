// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeterBar",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "MeterBar",
            targets: ["MeterBar"]
        ),
    ],
    dependencies: [
        .package(path: "Packages/MeterBarShared")
    ],
    targets: [
        .target(
            name: "MeterBar",
            dependencies: [
                .product(name: "MeterBarShared", package: "MeterBarShared")
            ],
            path: "MeterBar",
            exclude: [
                "App/MeterBarApp.swift",
                "MeterBar.entitlements",
                "Assets.xcassets",
                "Resources"
            ],
            // Match the Xcode app target (SWIFT_VERSION = 5.0). The views target
            // macOS 26 for Liquid Glass APIs, but stay in Swift 5 language mode so
            // existing singletons compile without a concurrency refactor.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MeterBarTests",
            dependencies: [
                "MeterBar",
                .product(name: "MeterBarShared", package: "MeterBarShared")
            ],
            path: "MeterBarTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
