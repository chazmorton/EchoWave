// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EchoWave",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "EchoWave", targets: ["EchoWave"])
    ],
    targets: [
        .executableTarget(
            name: "EchoWave",
            path: "Sources/EchoWave",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
