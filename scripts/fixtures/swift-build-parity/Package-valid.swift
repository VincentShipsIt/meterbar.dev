// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeterBar",
    targets: [
        .target(
            name: "MeterBar",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self)
            ]
        ),
        .testTarget(
            name: "MeterBarTests",
            dependencies: ["MeterBar"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self)
            ]
        )
    ]
)
