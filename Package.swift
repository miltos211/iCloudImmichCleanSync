// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "photo-exporter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "photo-exporter", targets: ["PhotoExporter"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        // Shared logic (PhotoKit integration, Models)
        .target(
            name: "ImmichShared",
            dependencies: [],
            path: "Sources/Shared"
        ),
        
        // Existing CLI Tool
        .executableTarget(
            name: "PhotoExporter",
            dependencies: [
                "ImmichShared",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/CLI"
        ),
        
        // New macOS App
        .executableTarget(
            name: "ImmichUploader",
            dependencies: ["ImmichShared"],
            path: "Sources/App",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/App/Info.plist"
                ])
            ]
        )
    ]
)