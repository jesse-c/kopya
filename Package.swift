// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Kopya",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.21.0"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0")
    ],
    targets: [
        .executableTarget(
            name: "Kopya",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Vapor", package: "vapor")
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "KopyaTests",
            dependencies: [
                "Kopya",
                .product(name: "XCTVapor", package: "vapor")
            ]
        )
    ]
)
