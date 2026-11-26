// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HostManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HostManager", targets: ["HostManager"]),
        .library(name: "HostManagerCore", targets: ["HostManagerCore"]),
    ],
    targets: [
        // Pure Foundation logic: the hosts grammar, the group tree, store and helper protocol.
        // Kept free of AppKit so it can be tested without a GUI.
        .target(name: "HostManagerCore"),
        .executableTarget(
            name: "HostManager",
            dependencies: ["HostManagerCore"]
        ),
    ]
)
