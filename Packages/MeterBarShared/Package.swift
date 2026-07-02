// swift-tools-version: 5.9
import PackageDescription

// Shared wire-format models for the MeterBar app, widget extension, and CLI.
// Kept at macOS 13 / tools 5.9 so MeterBarCLI (the lowest-targeting consumer)
// can depend on it unchanged.
let package = Package(
    name: "MeterBarShared",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MeterBarShared", targets: ["MeterBarShared"])
    ],
    targets: [
        .target(
            name: "MeterBarShared",
            path: "Sources/MeterBarShared"
        )
    ]
)
