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
                "Info.plist",
                "MeterBar.entitlements",
                "Assets.xcassets"
            ],
            // The provider logos ship as loose SVGs the app reads from its own
            // bundle. Excluding `Resources` here meant `swift test` had no
            // logos at all, so anything that drew one silently fell back to an
            // SF Symbol and no test could tell the difference — which is
            // exactly how a share card ended up with a terminal glyph where
            // Codex's mark belongs. Copied (not processed) so the lookup path
            // is the same subdirectory in both builds.
            resources: [
                .copy("Resources")
            ],
            // Match the Xcode app target (SWIFT_VERSION = 5.0,
            // SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor). The views target
            // macOS 26 for Liquid Glass APIs, but stay in Swift 5 language mode so
            // existing singletons compile without a concurrency refactor.
            // MainActor default isolation must match the app build, or tests
            // compile with different threading semantics than what ships.
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self)
            ]
        ),
        .testTarget(
            name: "MeterBarTests",
            dependencies: [
                "MeterBar",
                .product(name: "MeterBarShared", package: "MeterBarShared")
            ],
            path: "MeterBarTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self)
            ]
        ),
    ]
)
