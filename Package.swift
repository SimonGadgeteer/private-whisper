// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LocalDictation",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LocalDictation",
            dependencies: ["whisper"],
            path: "Sources/LocalDictation",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ServiceManagement"),
                // The whisper.framework is embedded in the app bundle by scripts/build_app.sh
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .binaryTarget(
            name: "whisper",
            path: "Frameworks/whisper.xcframework"
        ),
    ]
)
