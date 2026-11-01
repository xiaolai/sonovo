// swift-tools-version: 6.4
import PackageDescription
import Foundation

// Swift Build's PIF backend does not currently forward the CLI -Xswiftc
// warnings flag into target settings. Make the requested gate explicit for
// our production targets without imposing unsafe flags on library consumers.
let projectSwiftSettings: [SwiftSetting] =
    ProcessInfo.processInfo.environment["SONOVO_WARNINGS_AS_ERRORS"] == "1"
        ? [.unsafeFlags(["-warnings-as-errors"])] : []

// Native link requirements belong to the runtime that consumes Ghostty.
let terminalLinkerSettings: [LinkerSetting] = [
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
        .target(name: "SonovoTestFixtures", path: "Tests/SonovoTestFixtures", resources: [.copy("Fixtures")], swiftSettings: projectSwiftSettings),
        .testTarget(name: "SonovoMarkdownFeatureTests", dependencies: ["SonovoMarkdownFeature", "SonovoMarkdownEngine", "SonovoTextEngine", "SonovoDomainTypes", "SonovoDocumentSupport", "SonovoFileIO", "SonovoDesignSystem", "SonovoFeatureAPI", "SonovoDiagramUI", "SonovoDiagramEngine", "SonovoWorkflowEngine"]),
        .testTarget(name: "SonovoSubtitleFeatureTests", dependencies: ["SonovoSubtitleFeature", "SonovoSubtitleEngine", "SonovoDesignSystem", "SonovoTextEngine", "SonovoDomainTypes", "SonovoFileIO", "SonovoFeatureAPI"]),
        .testTarget(name: "SonovoMDXFeatureTests", dependencies: ["SonovoMDXFeature", "SonovoMDXKit", "SonovoDomainTypes", "SonovoFileIO", "SonovoFeatureAPI"]),
        .testTarget(name: "SonovoDiagramUITests", dependencies: ["SonovoDiagramUI", "SonovoDiagramEngine", "SonovoFileIO"]),
        .testTarget(name: "SonovoViewerFeatureTests", dependencies: ["SonovoViewerFeature", "SonovoDomainTypes", "SonovoFileIO", "SonovoDesignSystem", "SonovoWebSupport"]),
        .testTarget(name: "SonovoImageSupportTests", dependencies: ["SonovoImageSupport", "SonovoFileIO"]),
        .testTarget(name: "SonovoModel3DFeatureTests", dependencies: ["SonovoModel3DFeature", "SonovoDomainTypes", "SonovoFileIO", "SonovoDesignSystem", "SonovoWebSupport"]),
        .testTarget(name: "SonovoMediaEngineTests", dependencies: ["SonovoMediaEngine", "SonovoDomainTypes", "SonovoFileIO", "SonovoDocumentSupport", "SonovoSubtitleEngine", "SonovoTestFixtures"]),
        .testTarget(name: "SonovoMediaUITests", dependencies: ["SonovoMediaUI", "SonovoMediaEngine", "SonovoDomainTypes", "SonovoFileIO", "SonovoDesignSystem", "SonovoTestFixtures"]),
        .testTarget(name: "SonovoMediaFeatureTests", dependencies: ["SonovoMediaFeature", "SonovoMediaEngine", "SonovoDomainTypes", "SonovoDesignSystem", "SonovoFeatureAPI"]),
        .testTarget(name: "SonovoTimelineFeatureTests", dependencies: ["SonovoTimelineFeature", "SonovoMediaEngine", "SonovoDomainTypes", "SonovoFileIO", "SonovoDocumentSupport", "SonovoFeatureAPI", "SonovoTestFixtures"]),
        .testTarget(name: "SonovoCodeFeatureTests", dependencies: ["SonovoCodeFeature", "SonovoTextEngine", "SonovoFileIO", "SonovoDomainTypes", "SonovoDocumentSupport", "SonovoFeatureAPI", "SonovoDesignSystem"]),
              .testTarget(name: "SonovoTerminalFeatureTests", dependencies: ["SonovoTerminalFeature", "SonovoFileIO", "SonovoDomainTypes", "SonovoDesignSystem", "GhosttyKit"]),
        .target(name: "SonovoTerminalFeature", dependencies: ["SonovoFeatureAPI", "GhosttyKit", "SonovoFileIO", "SonovoDomainTypes", "SonovoDesignSystem"], resources: [.copy("Resources/ghostty"), .copy("Resources/ghostty-themes"), .copy("Resources/terminfo")], swiftSettings: projectSwiftSettings, linkerSettings: terminalLinkerSettings),
        .target(name: "SonovoMediaEngine", dependencies: ["SonovoFileIO", "SonovoDomainTypes", "SonovoDocumentSupport", "SonovoSubtitleEngine"], swiftSettings: projectSwiftSettings),
        .target(name: "SonovoMediaUI", dependencies: ["SonovoFileIO", "SonovoDomainTypes", "SonovoDocumentSupport", "SonovoDesignSystem", "SonovoMediaEngine"], swiftSettings: projectSwiftSettings),
        .target(name: "SonovoMediaFeature", dependencies: ["SonovoFileIO", "SonovoDomainTypes", "SonovoDocumentSupport", "SonovoDesignSystem", "SonovoFeatureAPI", "SonovoMediaEngine", "SonovoMediaUI"], swiftSettings: projectSwiftSettings),
        .target(name: "SonovoTimelineFeature", dependencies: ["SonovoFileIO", "SonovoDomainTypes", "SonovoDocumentSupport", "SonovoDesignSystem", "SonovoFeatureAPI", "SonovoMediaEngine", "SonovoMediaUI"], swiftSettings: projectSwiftSettings),
        .target(name: "SonovoModel3DFeature", dependencies: ["SonovoFileIO", "SonovoDomainTypes", "SonovoDesignSystem", "SonovoFeatureAPI", "SonovoWebSupport"], resources: [.copy("Resources/ModelViewer")], swiftSettings: projectSwiftSettings),
        .target(name: "SonovoSubtitleFeature", dependencies: ["SonovoSubtitleEngine", "SonovoFileIO", "SonovoDocumentSupport", "SonovoDomainTypes", "SonovoTextEngine", "SonovoDesignSystem", "SonovoFeatureAPI"], swiftSettings: projectSwiftSettings),
        .target(name: "SonovoMDXFeature", dependencies: ["SonovoMDXKit", "SonovoFileIO", "SonovoDocumentSupport", "SonovoDomainTypes", "SonovoTextEngine", "SonovoDesignSystem", "SonovoFeatureAPI"], swiftSettings: projectSwiftSettings),
        .target(name: "SonovoImageSupport", swiftSettings: projectSwiftSettings),
        .target(name: "SonovoMarkdownFeature", dependencies: ["SonovoMarkdownEngine", "SonovoFileIO", "SonovoDocumentSupport", "SonovoDomainTypes", "SonovoTextEngine", "SonovoDesignSystem", "SonovoFeatureAPI", "SonovoImageSupport", "SonovoWorkflowEngine", "SonovoDiagramEngine", "SonovoDiagramUI", "SwiftMath"], swiftSettings: projectSwiftSettings),
        .target(name: "SonovoCodeFeature", dependencies: ["SonovoFileIO", "SonovoTextEngine", "SonovoDomainTypes", "SonovoDesignSystem", "SonovoFeatureAPI", "SonovoDocumentSupport", "SonovoWorkflowEngine", "SonovoDiagramEngine", "SonovoDiagramUI"], swiftSettings: projectSwiftSettings),
        .target(name: "SonovoTextEngine", dependencies: ["SonovoFileIO", "SonovoDomainTypes"], swiftSettings: projectSwiftSettings),
        .target(name: "SonovoWebSupport", swiftSettings: projectSwiftSettings),
        .target(name: "SonovoViewerFeature", dependencies: ["SonovoWebSupport", "SonovoDomainTypes", "SonovoDesignSystem", "SonovoFileIO", "SonovoFeatureAPI"], swiftSettings: projectSwiftSettings),
        .target(name: "SonovoWorkflowEngine", dependencies: ["SonovoDomainTypes", .product(name: "Yams", package: "Yams")], swiftSettings: projectSwiftSettings),
        .target(name: "SonovoDiagramEngine", dependencies: ["SonovoFileIO", "SonovoDomainTypes", "SonovoWorkflowEngine"], swiftSettings: projectSwiftSettings),
        .target(name: "SonovoDiagramUI", dependencies: ["SonovoDocumentSupport", "SonovoDomainTypes", "SonovoFileIO", "SonovoDiagramEngine", "SonovoWorkflowEngine"], resources: [.copy("Resources/mermaid-12.2.0.min.js"), .copy("Resources/viz-global-3.31.0.min.js"), .copy("Resources/markmap-0.18.12.min.js")], swiftSettings: projectSwiftSettings),
        .testTarget(name: "SonovoWorkflowEngineTests", dependencies: ["SonovoWorkflowEngine", "SonovoDiagramEngine", "SonovoDomainTypes"]),
        .target(name: "SonovoDomainTypes", dependencies: ["SonovoFileIO"], swiftSettings: projectSwiftSettings),
        .target(name: "SonovoDocumentSupport", dependencies: ["SonovoFileIO", "SonovoDomainTypes"], swiftSettings: projectSwiftSettings),
        .target(name: "SonovoFeatureAPI", dependencies: ["SonovoFileIO", "SonovoDomainTypes", "SonovoDocumentSupport"], swiftSettings: projectSwiftSettings),
        .target(name: "SonovoWorkspaceHost", dependencies: ["SonovoFileIO", "SonovoDomainTypes", "SonovoFeatureAPI", "SonovoDocumentSupport", "SonovoDesignSystem"], swiftSettings: projectSwiftSettings),
        .testTarget(name: "SonovoWorkspaceHostTests", dependencies: ["SonovoWorkspaceHost", "SonovoFeatureAPI", "SonovoDomainTypes", "SonovoDocumentSupport"]),
        .testTarget(name: "SonovoDocumentSupportTests", dependencies: ["SonovoDocumentSupport"]),
        .target(
            name: "SonovoDesignSystem",
            dependencies: ["SonovoDomainTypes", "SonovoTextEngine"],
            resources: [.copy("Resources/ReadingThemes")],
            swiftSettings: projectSwiftSettings
        ),
        .testTarget(
            name: "SonovoDesignSystemTests",
            dependencies: ["SonovoDesignSystem"]
        ),
        .target(
            name: "SonovoFileIO",
            swiftSettings: projectSwiftSettings
        ),
        .testTarget(
            name: "SonovoFileIOTests",
            dependencies: ["SonovoFileIO"]
        ),
        .target(name: "SonovoMarkdownEngine", dependencies: ["SonovoWorkflowEngine", "SonovoDiagramEngine", "SonovoDomainTypes", "SonovoDocumentSupport", "SonovoTextEngine", "SonovoFileIO", .product(name: "Markdown", package: "swift-markdown")], swiftSettings: projectSwiftSettings),
        .target(name: "SonovoSubtitleEngine", dependencies: ["SonovoDomainTypes", "SonovoDocumentSupport", "SonovoTextEngine", "SonovoFileIO"], swiftSettings: projectSwiftSettings),
        .testTarget(name: "SonovoCoreTests", dependencies: ["SonovoCore"]),
        .target(name: "SonovoCore", dependencies: ["SonovoMarkdownEngine", "SonovoSubtitleEngine", "SonovoFileIO"], swiftSettings: projectSwiftSettings),
        // The MDX compiler runs only in the helper process; the kit is linked
        // by that helper and by tests. The app target links it for the shared
        // request, response, import-graph, and page-building types.
        .target(
            name: "SonovoMDXKit",
            dependencies: ["SonovoFileIO"],
            path: "Sources/SonovoMDXKit",
            resources: [.copy("Resources/mdx-compiler-3.1.1.js"), .copy("Resources/mdx-runtime-19.3.1.js")],
            swiftSettings: projectSwiftSettings
        ),
        .executableTarget(
            name: "SonovoMDXHelper",
            dependencies: ["SonovoMDXKit"],
            path: "Sources/SonovoMDXHelper",
            swiftSettings: projectSwiftSettings
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
                "SonovoTerminalFeature", "SonovoMediaEngine", "SonovoMediaUI", "SonovoMediaFeature", "SonovoTimelineFeature", "SonovoModel3DFeature", "SonovoSubtitleFeature", "SonovoMDXFeature", "SonovoMarkdownFeature", "SonovoImageSupport", "SonovoCodeFeature", "SonovoWebSupport", "SonovoViewerFeature", "SonovoWorkflowEngine", "SonovoDiagramEngine", "SonovoDiagramUI",
                "SonovoTextEngine", "SonovoDomainTypes", "SonovoDocumentSupport", "SonovoFeatureAPI", "SonovoWorkspaceHost",
                "SonovoDesignSystem",
                "SonovoFileIO",
                "SonovoMarkdownEngine", "SonovoSubtitleEngine",
                "SonovoMDXKit",
            ],
            path: "Sources/Sonovo",
            resources: [
                .copy("Resources/version.txt"),
                .copy("Resources/AppIcon.png"),
                .copy("Resources/SampleProject")
            ],
            swiftSettings: projectSwiftSettings
        ),
        .testTarget(
            name: "SonovoMarkdownEngineTests",
            dependencies: [
                "SonovoWorkflowEngine", "SonovoDiagramEngine",
                "SonovoTextEngine", "SonovoDomainTypes", "SonovoDocumentSupport",
                "SonovoMarkdownEngine",
                "SonovoFileIO",
                "ReferenceAst"
            ],
            path: "Tests/SonovoMarkdownEngineTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(name: "SonovoSubtitleEngineTests", dependencies: ["SonovoSubtitleEngine", "SonovoFileIO", "SonovoDocumentSupport", "SonovoTextEngine", "SonovoDomainTypes"]),
        .testTarget(
            name: "SonovoMDXKitTests",
            dependencies: ["SonovoMDXKit"],
            path: "Tests/SonovoMDXKitTests"
        ),
        .testTarget(
            name: "SonovoAppTests",
            dependencies: [
                "SonovoTestFixtures",
                "SonovoTerminalFeature", "SonovoMediaEngine", "SonovoMediaUI", "SonovoMediaFeature", "SonovoTimelineFeature", "SonovoModel3DFeature", "SonovoSubtitleFeature", "SonovoMDXFeature", "SonovoMarkdownFeature", "SonovoImageSupport", "SonovoCodeFeature", "SonovoWebSupport", "SonovoViewerFeature", "SonovoWorkflowEngine", "SonovoDiagramEngine", "SonovoDiagramUI",
                "SonovoTextEngine", "SonovoDomainTypes", "SonovoDocumentSupport", "SonovoFeatureAPI", "SonovoWorkspaceHost",
                "SonovoDesignSystem",
                "Sonovo",
                "SonovoMarkdownEngine", "SonovoSubtitleEngine"
            ],
            path: "Tests/SonovoAppTests"
        )
    ]
)
