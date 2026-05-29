// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrafficLight",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TrafficLight", targets: ["TrafficLight"])
    ],
    targets: [
        .executableTarget(
            name: "TrafficLight",
            path: "Sources/TrafficLight"
        )
    ]
)
