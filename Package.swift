// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode: Silk deliberately uses threads + main-thread confinement
// (AX objects are bound to per-app threads), which strict concurrency can't express.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
]

let package = Package(
    name: "Silk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SilkApp", targets: ["SilkApp"]),
        .executable(name: "silk", targets: ["silk"]),
    ],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder", exact: "0.4.4"),
    ],
    targets: [
        // C shim exposing stable private symbols (_AXUIElementGetWindow, SkyLight process helpers).
        .target(name: "SilkPrivateAPI", path: "Sources/SilkPrivateAPI", publicHeadersPath: "include"),
        .target(
            name: "SilkConfig",
            dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        .target(name: "SilkCore", dependencies: ["SilkConfig"], swiftSettings: swiftSettings),
        .target(name: "SilkPlatform", dependencies: ["SilkPrivateAPI"], swiftSettings: swiftSettings),
        .target(name: "SilkAnimation", swiftSettings: swiftSettings),
        .target(name: "SilkIPC", swiftSettings: swiftSettings),
        .executableTarget(
            name: "SilkApp",
            dependencies: ["SilkConfig", "SilkCore", "SilkPlatform", "SilkAnimation", "SilkIPC"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(name: "silk", dependencies: ["SilkIPC"], swiftSettings: swiftSettings),
        .testTarget(
            name: "SilkConfigTests",
            dependencies: ["SilkConfig"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "SilkCoreTests", dependencies: ["SilkCore"], swiftSettings: swiftSettings),
        .testTarget(name: "SilkAnimationTests", dependencies: ["SilkAnimation"], swiftSettings: swiftSettings),
    ]
)
