// swift-tools-version:5.9
import PackageDescription

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
            resources: [.copy("Resources/gbk-table.bin")]
        ),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"]),
    ]
)
