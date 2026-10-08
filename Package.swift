// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Quickclean",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "QuickcleanCore", targets: ["QuickcleanCore"]),
        .executable(name: "qc", targets: ["qc"]),
    ],
    targets: [
        .target(name: "QuickcleanCore", resources: [.process("Resources")]),
        .executableTarget(name: "qc", dependencies: ["QuickcleanCore"]),
        .testTarget(
            name: "QuickcleanCoreTests",
            dependencies: ["QuickcleanCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
