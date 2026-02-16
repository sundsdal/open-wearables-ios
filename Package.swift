// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenWearablesHealthCore",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "OpenWearablesHealthCore", targets: ["OpenWearablesHealthCore"])
    ],
    targets: [
        .target(
            name: "OpenWearablesHealthCore",
            dependencies: [],
            path: "Sources/OpenWearablesHealthCore"
        ),
        .testTarget(
            name: "OpenWearablesHealthCoreTests",
            dependencies: ["OpenWearablesHealthCore"],
            path: "Tests/OpenWearablesHealthCoreTests"
        )
    ]
)
