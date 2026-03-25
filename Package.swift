// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ButteryUpdater",
    platforms: [
        .macOS(.v15),
        .iOS(.v17),
    ],
    products: [
        // Core update service — check, download, verify, install, relaunch.
        // No SwiftUI dependency. Suitable for headless apps (DAIS, Server).
        .library(
            name: "ButteryUpdater",
            targets: ["ButteryUpdater"]
        ),
        // SwiftUI layer — AppUpdateManager, alert modifier, progress overlay.
        // For GUI apps (Sous, ButteryAI).
        .library(
            name: "ButteryUpdaterUI",
            targets: ["ButteryUpdaterUI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "ButteryUpdater",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ButteryUpdaterUI",
            dependencies: ["ButteryUpdater"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ButteryUpdaterTests",
            dependencies: ["ButteryUpdater"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
