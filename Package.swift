// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sonovo",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Sonovo", targets: ["Sonovo"])
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "Vendor/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "Sonovo",
            dependencies: ["GhosttyKit"],
            path: "Sources/Sonovo",
            resources: [
                .copy("Resources/ghostty"),
                .copy("Resources/ghostty-themes"),
                .copy("Resources/terminfo"),
                .copy("Resources/version.txt"),
                .copy("Resources/AppIcon.png")
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedLibrary("z"),
                .linkedLibrary("c++")
            ]
        )
    ]
)
