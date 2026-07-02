// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeterBarCLI",
    // Matches the app's deployment target: the CLI ships inside MeterBar.app
    // (Contents/Helpers/meterbar), so it only ever runs where the app runs.
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "meterbar", targets: ["MeterBarCLI"])
    ],
    dependencies: [
        // The app's library: MetricsCodec, CostSummaryStore, UsageFormatting,
        // QuotaBands, and SharedDataStore. Replaces the CLI's hand-maintained
        // copies of that logic, which had drifted (an Int-vs-Double mismatch
        // once silently emptied all CLI output).
        .package(name: "MeterBar", path: ".."),
        // The wire-format types (ServiceType/UsageMetrics/UsageLimit) — same
        // package the app and widget decode with, so all three agree.
        .package(path: "../Packages/MeterBarShared"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "MeterBarCLI",
            dependencies: [
                .product(name: "MeterBar", package: "MeterBar"),
                .product(name: "MeterBarShared", package: "MeterBarShared"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources",
            // Same language mode as the app library.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
