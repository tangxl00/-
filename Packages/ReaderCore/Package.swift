// swift-tools-version:6.0
import PackageDescription

// 说明（v1.2.0）：tools-version 由 5.9 提到 6.0。
// 原因：源码使用 `nonisolated(unsafe)` 与 `URLSession.data(for:)`，二者要求 ≥5.10；
// 5.9.2 工具链会在编译期直接失败（质检实测）。
// 语言模式仍锁定 v5：Swift 6 语言模式的严格并发检查会把既有大量无关代码与测试判为错误，
// 属于与本次修复无关的重构，不在本次范围内。
let package = Package(
    name: "ReaderCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReaderCore", targets: ["ReaderCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.7.5"),
    ],
    targets: [
        .target(
            name: "ReaderCore",
            dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")],
            resources: [.copy("Resources/gbk-table.bin")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ReaderCoreTests",
            dependencies: ["ReaderCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
