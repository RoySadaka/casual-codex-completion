// swift-tools-version: 5.8

import PackageDescription

let package = Package(
    name: "CCC",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "CCC",
            targets: ["CCCApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "CCCApp",
            path: "Sources/CCCApp"
        )
    ]
)
