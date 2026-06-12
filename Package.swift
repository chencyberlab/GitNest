// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GitNest",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "GitNest",
            path: "Sources/GitNest"
        ),
        .testTarget(
            name: "GitNestTests",
            dependencies: ["GitNest"],
            path: "Tests/GitNestTests"
        )
    ]
)
