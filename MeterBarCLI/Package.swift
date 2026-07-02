// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeterBarCLI",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "meterbar", targets: ["MeterBarCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(path: "../Packages/MeterBarShared")
    ],
    targets: [
        .executableTarget(
            name: "MeterBarCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MeterBarShared", package: "MeterBarShared")
            ],
            path: "Sources"
        )
    ]
)
