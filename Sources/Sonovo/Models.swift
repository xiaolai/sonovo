import SonovoCore
import SwiftUI

enum AssetKind: String, Hashable, Sendable {
    case script
    case document
    case audio
    case video
    case stills
    case image
    case subtitle
    case model3d
    case html
    case archive
    case delivery
    case other
    case code

    var icon: String {
        switch self {
        case .script: "doc.text"
        case .document: "doc.richtext"
        case .audio: "waveform"
        case .video: "film"
        case .stills: "photo.on.rectangle.angled"
        case .image: "photo"
        case .subtitle: "captions.bubble"
        case .model3d: "cube.transparent"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .archive: "archivebox"
        case .delivery: "shippingbox"
        case .other: "questionmark.square.dashed"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }

    var tabIcon: String {
        switch self {
        case .stills: "photo"
        case .model3d: "cube"
        case .html: "globe"
        case .code: "chevron.left.forwardslash.chevron.right"
        default: icon
        }
    }

    var workspaceTitle: String {
        switch self {
        case .script: "Script"
        case .subtitle: "Subtitles"
        case .model3d: "3D"
        default: "Workspace"
        }
    }
}

struct ProductionAsset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
    let kind: AssetKind

    var shortDetail: String {
        detail.components(separatedBy: " · ").first ?? detail
    }
}

struct ProductionStage: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let assets: [ProductionAsset]
}

struct Production: Hashable, Sendable {
    let title: String
    let episode: String
    let updated: String
    let stages: [ProductionStage]

    var allAssets: [ProductionAsset] {
        stages.flatMap(\.assets)
    }

    func asset(id: String) -> ProductionAsset? {
        allAssets.first { $0.id == id }
    }

    func stage(for assetID: String) -> ProductionStage? {
        stages.first { stage in stage.assets.contains { $0.id == assetID } }
    }

    static let sample = Production(
        title: "Tidewater",
        episode: "Ep. 01 · The Harbor at Six",
        updated: "Voiceover updated 2 min ago",
        stages: [
            ProductionStage(id: "script", title: "Script", assets: [
                ProductionAsset(
                    id: "script-md",
                    name: "tidewater-script.md",
                    detail: "Narration draft · 1,240 words",
                    kind: .script
                ),
                ProductionAsset(
                    id: "outline-md",
                    name: "outline.md",
                    detail: "Beat sheet · 12 beats",
                    kind: .script
                )
            ]),
            ProductionStage(id: "subtitles", title: "Subtitles", assets: [
                ProductionAsset(
                    id: "captions-srt",
                    name: "captions.srt",
                    detail: "Subtitle track · SRT · 3 cues",
                    kind: .subtitle
                )
            ]),
            ProductionStage(id: "voice", title: "Voice", assets: [
                ProductionAsset(
                    id: "vo-take-03",
                    name: "vo-take-03.wav",
                    detail: "00:12.4 · 48 kHz · Stereo",
                    kind: .audio
                ),
                ProductionAsset(
                    id: "vo-take-02",
                    name: "vo-take-02.wav",
                    detail: "00:12.8 · 48 kHz · Stereo",
                    kind: .audio
                )
            ]),
            ProductionStage(id: "visuals", title: "Visuals", assets: [
                ProductionAsset(
                    id: "stills",
                    name: "Stills — 8 frames",
                    detail: "Harbor · Dawn · 2048 px",
                    kind: .stills
                ),
                ProductionAsset(
                    id: "broll",
                    name: "B-roll — 4 clips",
                    detail: "Water · Boats · Town",
                    kind: .video
                )
            ]),
            ProductionStage(id: "models", title: "3D Models", assets: [
                ProductionAsset(
                    id: "model-3d",
                    name: "3D Models",
                    detail: "GLB · STL · 3MF · USDZ",
                    kind: .model3d
                )
            ]),
            ProductionStage(id: "takes", title: "Takes", assets: [
                ProductionAsset(
                    id: "take-03",
                    name: "take-03.mp4",
                    detail: "00:12.4 · 1920×1080 · H.264",
                    kind: .video
                ),
                ProductionAsset(
                    id: "take-02",
                    name: "take-02.mp4",
                    detail: "00:12.8 · 1920×1080 · H.264",
                    kind: .video
                )
            ]),
            ProductionStage(id: "delivery", title: "Delivery", assets: [
                ProductionAsset(
                    id: "storyboard-html",
                    name: "storyboard.html",
                    detail: "Web storyboard · 8 scenes",
                    kind: .html
                ),
                ProductionAsset(
                    id: "render-1080",
                    name: "Tidewater — 1080p.mp4",
                    detail: "Not rendered",
                    kind: .delivery
                )
            ])
        ]
    )
}

enum EditorTabContent: Hashable, Sendable {
    case sample(ProductionAsset)
    case project(ProjectAsset)
    /// A workspace with no file yet: the empty state is the content.
    case workspace(AssetKind)
}

struct EditorTab: Identifiable, Hashable, Sendable {
    let id: String
    let assetID: String
    let title: String
    let kind: AssetKind
    let icon: String
    /// The file this tab owns in a real project. Nil for a sample tab.
    let url: URL?
    let content: EditorTabContent

    init(asset: ProductionAsset) {
        id = asset.id
        assetID = asset.id
        title = asset.name
        kind = asset.kind
        icon = asset.kind.tabIcon
        url = nil
        content = .sample(asset)
    }

    init(asset: ProjectAsset) {
        id = asset.id
        assetID = asset.id
        title = asset.name
        kind = asset.kind
        icon = asset.kind.tabIcon
        url = asset.url
        content = .project(asset)
    }

    init(workspaceKind kind: AssetKind) {
        id = "workspace-\(kind.rawValue)"
        assetID = id
        title = kind.workspaceTitle
        self.kind = kind
        icon = kind.tabIcon
        url = nil
        content = .workspace(kind)
    }

    var projectAsset: ProjectAsset? {
        if case .project(let asset) = content { return asset }
        return nil
    }

    var sampleAsset: ProductionAsset? {
        if case .sample(let asset) = content { return asset }
        return nil
    }

    /// The workspace kind when this is a synthetic workspace tab. Such a tab
    /// has no URL; its identity is the document selected inside it.
    var workspaceKind: AssetKind? {
        if case .workspace(let kind) = content { return kind }
        return nil
    }
}

enum EditorMode: String, CaseIterable, Identifiable, Sendable {
    case player
    case compare
    case transcript

    var id: String { rawValue }

    var label: String {
        switch self {
        case .player: "Player"
        case .compare: "Compare"
        case .transcript: "Transcript"
        }
    }

    var icon: String {
        switch self {
        case .player: "play.rectangle"
        case .compare: "rectangle.split.2x1"
        case .transcript: "text.quote"
        }
    }
}

enum NavigatorMode: String, CaseIterable, Identifiable, Sendable {
    case production
    case files

    var id: String { rawValue }

    var label: String {
        switch self {
        case .production: "Production"
        case .files: "Files"
        }
    }

    var icon: String {
        switch self {
        case .production: "square.stack.3d.up"
        case .files: "folder"
        }
    }
}

struct TranscriptSegment: Identifiable, Hashable, Sendable {
    let id: String
    let start: Double
    let end: Double
    let speaker: String
    let text: String

    var timecode: String {
        Self.timecode(for: start)
    }

    static func timecode(for seconds: Double) -> String {
        // Round to the displayed precision first. Truncating the fractional
        // part separately turns 4.6 into 4 seconds + 59 hundredths.
        // Transcript timestamps come from a file and may be NaN or infinite;
        // a raw `Int(_:)` would trap.
        let totalHundredths =
            NumericConversion.int(seconds.isFinite ? max(0, seconds) * 100 : 0)
            ?? 0
        let hundredths = totalHundredths % 100
        let totalSeconds = totalHundredths / 100
        let minutes = totalSeconds / 60
        let wholeSeconds = totalSeconds % 60
        return String(
            format: "%02d:%02d.%02d",
            minutes,
            wholeSeconds,
            hundredths
        )
    }
}

struct FileNode: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let icon: String
    let assetID: String?
    var children: [FileNode]?

    /// Filters a tree while keeping the ancestors of matching descendants.
    /// A matching folder keeps its whole subtree.
    static func filtered(_ nodes: [FileNode], query: String) -> [FileNode] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nodes }
        return nodes.compactMap { node in
            if node.name.localizedCaseInsensitiveContains(trimmed) {
                return node
            }
            guard let children = node.children else { return nil }
            let matches = filtered(children, query: trimmed)
            guard !matches.isEmpty else { return nil }
            var copy = node
            copy.children = matches
            return copy
        }
    }
}

enum SampleContent {
    static let transcript: [TranscriptSegment] = [
        TranscriptSegment(
            id: "seg-1",
            start: 0,
            end: 3.2,
            speaker: "Narrator",
            text: "The harbor wakes before the town does."
        ),
        TranscriptSegment(
            id: "seg-2",
            start: 3.2,
            end: 7.1,
            speaker: "Narrator",
            text: "Fog sits on the water like a held breath."
        ),
        TranscriptSegment(
            id: "seg-3",
            start: 7.1,
            end: 10.4,
            speaker: "Narrator",
            text: "By six, the first boat is already out."
        ),
        TranscriptSegment(
            id: "seg-4",
            start: 10.4,
            end: 12.4,
            speaker: "Narrator",
            text: "And the day begins the way it always has."
        )
    ]

    static let fileTree: [FileNode] = [
        FileNode(id: "file-script", name: "tidewater-script.md", icon: "doc.text", assetID: "script-md", children: nil),
        FileNode(id: "file-outline", name: "outline.md", icon: "doc.text", assetID: "outline-md", children: nil),
        FileNode(id: "file-captions", name: "captions.srt", icon: "captions.bubble", assetID: "captions-srt", children: nil),
        FileNode(id: "folder-voice", name: "voice", icon: "folder", assetID: nil, children: [
            FileNode(id: "file-vo-03", name: "vo-take-03.wav", icon: "waveform", assetID: "vo-take-03", children: nil),
            FileNode(id: "file-vo-02", name: "vo-take-02.wav", icon: "waveform", assetID: "vo-take-02", children: nil)
        ]),
        FileNode(id: "folder-visuals", name: "visuals", icon: "folder", assetID: nil, children: [
            FileNode(id: "folder-stills", name: "stills", icon: "folder", assetID: "stills", children: nil),
            FileNode(id: "folder-broll", name: "b-roll", icon: "folder", assetID: "broll", children: nil)
        ]),
        FileNode(id: "folder-models", name: "models", icon: "folder", assetID: nil, children: [
            FileNode(id: "file-model", name: "set-dressing.glb", icon: "cube.transparent", assetID: "model-3d", children: nil)
        ]),
        FileNode(id: "folder-takes", name: "takes", icon: "folder", assetID: nil, children: [
            FileNode(id: "file-take-03", name: "take-03.mp4", icon: "film", assetID: "take-03", children: nil),
            FileNode(id: "file-take-02", name: "take-02.mp4", icon: "film", assetID: "take-02", children: nil)
        ]),
        FileNode(id: "folder-delivery", name: "delivery", icon: "folder", assetID: nil, children: [
            FileNode(id: "file-storyboard", name: "storyboard.html", icon: "globe", assetID: "storyboard-html", children: nil),
            FileNode(id: "file-render", name: "Tidewater — 1080p.mp4", icon: "shippingbox", assetID: "render-1080", children: nil)
        ])
    ]
}
