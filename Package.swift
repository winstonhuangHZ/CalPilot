// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CalPilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "calpilot", targets: ["calpilot"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "CalPilotCore"),
        .executableTarget(
            name: "calpilot",
            dependencies: [
                "CalPilotCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
