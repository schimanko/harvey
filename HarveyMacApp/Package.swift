// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HarveyMacApp",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "HarveyMacApp",
            path: "Sources"
        )
    ]
)