// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BookLibConnect-Mac",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "BookLibCore", targets: ["BookLibCore"]),
        .executable(name: "BookLibConnect", targets: ["BookLibConnect"]),
    ],
    targets: [
        .target(name: "BookLibCore"),
        .executableTarget(
            name: "BookLibConnect",
            dependencies: ["BookLibCore"]
        ),
        .testTarget(
            name: "BookLibCoreTests",
            dependencies: ["BookLibCore"]
        ),
    ]
)
