// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Kapture",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Kapture"),
        .testTarget(name: "KaptureTests", dependencies: ["Kapture"]),
    ]
)
