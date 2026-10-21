// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sonovo",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Sonovo", targets: ["Sonovo"]),
        .library(name: "SonovoCore", targets: ["SonovoCore"])
    ],
    dependencies: [
        // Pinned to the Swift 6.4.1 toolchain release. The parser attaches
        // table, strikethrough, and task-list; autolinks are added natively.
        .package(
            url: "https://github.com/swiftlang/swift-markdown.git",
            revision: "bc55d614bc8608d74cdc18d3aa6413bd8661e444"
        ),
        // swift-markdown requires this branch, and SwiftPM rejects mixing a
        // branch requirement with a revision requirement for one package.
        // Package.resolved pins the resolved revision
        // (08ddb528923cc1a6527e02b7a1aee9e516ca749a); commit it with the
        // manifest. ReferenceAst links the C API directly so the conformance
        // oracle is not the app's converter.
        .package(
            url: "https://github.com/swiftlang/swift-cmark.git",
            branch: "release/6.4.x"
        )
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "Vendor/GhosttyKit.xcframework"
        ),
        .target(
            name: "SonovoCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "Sources/SonovoCore"
        ),
        .target(
            name: "ReferenceAst",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark")
            ],
            path: "Sources/ReferenceAst"
        ),
        .executableTarget(
            name: "ReferenceAstTool",
            dependencies: ["ReferenceAst"],
            path: "Sources/ReferenceAstTool"
        ),
        .executableTarget(
            name: "Sonovo",
            dependencies: [
                "GhosttyKit",
                "SonovoCore"
            ],
            path: "Sources/Sonovo",
            resources: [
                .copy("Resources/ghostty"),
                .copy("Resources/ghostty-themes"),
                .copy("Resources/terminfo"),
                .copy("Resources/version.txt"),
                .copy("Resources/AppIcon.png"),
                .copy("Resources/ModelViewer"),
                .copy("Resources/SampleProject")
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
                .linkedFramework("AVFoundation"),
                .linkedLibrary("z"),
                .linkedLibrary("c++")
            ]
        ),
        .testTarget(
            name: "SonovoCoreTests",
            dependencies: [
                "SonovoCore",
                "ReferenceAst"
            ],
            path: "Tests/SonovoCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "SonovoAppTests",
            dependencies: [
                "Sonovo",
                "SonovoCore"
            ],
            path: "Tests/SonovoAppTests"
        )
    ]
)
