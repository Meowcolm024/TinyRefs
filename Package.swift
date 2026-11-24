// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let rustArchive = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("rust/biblatex-bridge/target/debug/libtinyrefs_biblatex.a")
    .path

let package = Package(
    name: "TinyRefs",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TinyRefs", targets: ["TinyRefs"]),
        .executable(name: "TinyRefsApp", targets: ["TinyRefsApp"]),
        .executable(name: "tinyrefs", targets: ["TinyRefsCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        .systemLibrary(name: "CBibLaTeX"),
        .target(
            name: "TinyRefs",
            dependencies: ["CBibLaTeX", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", rustArchive]),
            ],
        ),
        .executableTarget(name: "TinyRefsApp", dependencies: ["TinyRefs"]),
        .executableTarget(
            name: "TinyRefsCLI",
            dependencies: ["TinyRefs", .product(name: "ArgumentParser", package: "swift-argument-parser")],
        ),
        .testTarget(
            name: "TinyRefsTests",
            dependencies: ["TinyRefs", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
