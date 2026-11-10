// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Deceive",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Deceive",
            path: "Sources/Deceive"
        ),
        .testTarget(
            name: "DeceiveTests",
            dependencies: ["Deceive"],
            path: "Tests/DeceiveTests"
        ),
    ]
)
