// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Sonovo",
    platforms: [.macOS(.v27)],
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
        ),
        // Math typesetting is native: TeX is laid out by SwiftMath's Core
        // Graphics typesetter, with no JavaScript and no network. Pinned to
        // an exact release; the bundled math fonts carry their own
        // GUST/OFL/STIX licenses (see THIRD_PARTY_NOTICES.md).
        .package(
            url: "https://github.com/mgriebling/SwiftMath.git",
            exact: "1.7.3"
        ),
        // GitHub Actions workflow charts need a real YAML parser: the
        // workflow document's jobs and needs are read from the node tree,
        // not from a syntax-only scan. Pinned to an exact release; libyaml
        // is wrapped by the package and needs no system install.
        .package(
            url: "https://github.com/jpsim/Yams.git",
            exact: "6.2.2"
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
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/SonovoCore"
        ),
        // The MDX compiler runs only in the helper process; the kit is linked
        // by that helper and by tests. The app target links it for the shared
        // request, response, import-graph, and page-building types.
        .target(
            name: "SonovoMDXKit",
            path: "Sources/SonovoMDXKit"
        ),
        .executableTarget(
            name: "SonovoMDXHelper",
            dependencies: ["SonovoMDXKit"],
            path: "Sources/SonovoMDXHelper"
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
                "SonovoCore",
                "SonovoMDXKit",
                "SwiftMath"
            ],
            path: "Sources/Sonovo",
            resources: [
                .copy("Resources/ghostty"),
                .copy("Resources/ghostty-themes"),
                .copy("Resources/terminfo"),
                .copy("Resources/version.txt"),
                .copy("Resources/AppIcon.png"),
                .copy("Resources/ModelViewer"),
                .copy("Resources/ReadingThemes"),
                .copy("Resources/SampleProject"),
                .copy("Resources/mermaid-12.2.0.min.js"),
                .copy("Resources/viz-global-3.31.0.min.js"),
                .copy("Resources/markmap-0.18.12.min.js"),
                .copy("Resources/mdx-compiler-3.1.1.js"),
                .copy("Resources/mdx-runtime-19.3.1.js")
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
            name: "SonovoMDXKitTests",
            dependencies: ["SonovoMDXKit"],
            path: "Tests/SonovoMDXKitTests"
        ),
        .testTarget(
            name: "SonovoAppTests",
            dependencies: [
                "Sonovo",
                "SonovoCore"
            ],
            path: "Tests/SonovoAppTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
