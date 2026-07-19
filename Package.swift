// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "appshot",
    // macOS 14 is the true API floor (SCScreenshotManager.captureImage). The apps
    // that consume this are on macOS 26, but the tool has no reason to be.
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "appshot", targets: ["appshot"]),
        .library(name: "AppShotKit", targets: ["AppShotKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // All the logic. Returns values; never prints, never exits — which is what
        // makes the gate and the compositor testable as plain functions.
        .target(name: "AppShotKit"),
        // Thin CLI: parses arguments, calls AppShotKit, renders the results.
        .executableTarget(
            name: "appshot",
            dependencies: [
                "AppShotKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "AppShotKitTests", dependencies: ["AppShotKit"]),
        // Separate from AppShotKitTests so the kit's suite stays free of ArgumentParser.
        .testTarget(name: "appshotTests", dependencies: ["appshot"]),
    ]
)
