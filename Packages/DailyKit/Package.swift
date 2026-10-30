// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DailyKit",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DailyKit", targets: ["DailyKit"]),
        .library(name: "DailyUI", targets: ["DailyUI"]),
        .executable(name: "DailyDev", targets: ["DailyDev"]),
    ],
    targets: [
        .target(name: "DailyKit"),
        .target(name: "DailyUI", dependencies: ["DailyKit"]),
        .executableTarget(name: "DailyDev", dependencies: ["DailyKit", "DailyUI"]),
        .testTarget(name: "DailyKitTests", dependencies: ["DailyKit"]),
    ]
)
