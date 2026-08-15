// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AutumnMail",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AutumnMail", targets: ["AutumnMail"])
    ],
    targets: [
        .executableTarget(
            name: "AutumnMail",
            path: "Sources/AutumnMail"
        ),
        .testTarget(
            name: "AutumnMailTests",
            dependencies: ["AutumnMail"],
            path: "Tests/AutumnMailTests"
        )
    ]
)
