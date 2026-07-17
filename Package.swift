// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuotaCore", targets: ["QuotaCore"]),
    ],
    targets: [
        .target(name: "QuotaCore"),
        .testTarget(
            name: "QuotaCoreTests",
            dependencies: ["QuotaCore"],
            resources: [.process("Fixtures")]
        ),
    ]
)
