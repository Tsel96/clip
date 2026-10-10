// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CLIP",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CLIP", targets: ["CLIP"])
    ],
    targets: [
        .executableTarget(
            name: "CLIP",
            path: "Sources/CLIP",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "CLIPTests",
            dependencies: ["CLIP"],
            path: "Tests/CLIPTests"
        )
    ]
)
