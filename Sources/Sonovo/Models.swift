import SwiftUI

enum ReviewStatus: String, CaseIterable, Hashable, Sendable {
    case draft
    case generating
    case needsReview
    case approved

    var label: String {
        switch self {
        case .draft: "Draft"
        case .generating: "Generating"
        case .needsReview: "Needs review"
        case .approved: "Approved"
        }
    }

    var color: Color {
        switch self {
        case .draft: .secondary
        case .generating: .blue
        case .needsReview: .orange
        case .approved: .green
        }
    }

    var symbol: String {
        switch self {
        case .draft: "circle.dashed"
        case .generating: "sparkles"
        case .needsReview: "exclamationmark.circle.fill"
        case .approved: "checkmark.circle.fill"
        }
    }
}

enum AssetKind: String, Hashable, Sendable {
    case script
    case audio
    case video
    case stills
    case html
    case delivery

    var icon: String {
        switch self {
        case .script: "doc.text"
        case .audio: "waveform"
        case .video: "film"
        case .stills: "photo.on.rectangle.angled"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .delivery: "shippingbox"
        }
    }

    var tabIcon: String {
        switch self {
        case .script: "doc.text"
        case .audio: "waveform"
        case .video: "film"
        case .stills: "photo"
        case .html: "globe"
        case .delivery: "shippingbox"
        }
    }
}

struct ProductionAsset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
    let kind: AssetKind
    let status: ReviewStatus

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

    var needsReviewCount: Int {
        allAssets.filter { $0.status == .needsReview }.count
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
                    kind: .script,
                    status: .needsReview
                ),
                ProductionAsset(
                    id: "outline-md",
                    name: "outline.md",
                    detail: "Beat sheet · 12 beats",
                    kind: .script,
                    status: .approved
                )
            ]),
            ProductionStage(id: "voice", title: "Voice", assets: [
                ProductionAsset(
                    id: "vo-take-03",
                    name: "vo-take-03.wav",
                    detail: "00:12.4 · 48 kHz · Stereo",
                    kind: .audio,
                    status: .needsReview
                ),
                ProductionAsset(
                    id: "vo-take-02",
                    name: "vo-take-02.wav",
                    detail: "00:12.8 · 48 kHz · Stereo",
                    kind: .audio,
                    status: .approved
                )
            ]),
            ProductionStage(id: "visuals", title: "Visuals", assets: [
                ProductionAsset(
                    id: "stills",
                    name: "Stills — 8 frames",
                    detail: "Harbor · Dawn · 2048 px",
                    kind: .stills,
                    status: .needsReview
                ),
                ProductionAsset(
                    id: "broll",
                    name: "B-roll — 4 clips",
                    detail: "Water · Boats · Town",
                    kind: .video,
                    status: .draft
                )
            ]),
            ProductionStage(id: "takes", title: "Takes", assets: [
                ProductionAsset(
                    id: "take-03",
                    name: "take-03.mp4",
                    detail: "00:12.4 · 1920×1080 · H.264",
                    kind: .video,
                    status: .needsReview
                ),
                ProductionAsset(
                    id: "take-02",
                    name: "take-02.mp4",
                    detail: "00:12.8 · 1920×1080 · H.264",
                    kind: .video,
                    status: .approved
                )
            ]),
            ProductionStage(id: "delivery", title: "Delivery", assets: [
                ProductionAsset(
                    id: "storyboard-html",
                    name: "storyboard.html",
                    detail: "Web review · 8 scenes",
                    kind: .html,
                    status: .draft
                ),
                ProductionAsset(
                    id: "render-1080",
                    name: "Tidewater — 1080p.mp4",
                    detail: "Not rendered",
                    kind: .delivery,
                    status: .draft
                )
            ])
        ]
    )
}

struct EditorTab: Identifiable, Hashable, Sendable {
    let id: String
    let assetID: String
    let title: String
    let kind: AssetKind
    let icon: String

    init(asset: ProductionAsset) {
        id = asset.id
        assetID = asset.id
        title = asset.name
        kind = asset.kind
        icon = asset.kind.tabIcon
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

enum InspectorTab: String, CaseIterable, Identifiable, Sendable {
    case info
    case history
    case notes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .info: "Info"
        case .history: "History"
        case .notes: "Notes"
        }
    }

    var icon: String {
        switch self {
        case .info: "info.circle"
        case .history: "clock.arrow.circlepath"
        case .notes: "text.bubble"
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
        let clamped = max(0, seconds)
        let minutes = Int(clamped) / 60
        let wholeSeconds = Int(clamped) % 60
        let hundredths = Int((clamped - floor(clamped)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, wholeSeconds, hundredths)
    }
}

struct ReviewNote: Identifiable, Hashable, Sendable {
    let id: String
    let timecode: String
    let text: String
    let author: String
    let createdAt: String
    var isResolved: Bool
}

struct TakeVersion: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let status: ReviewStatus
    let createdAt: String
    let detail: String
}

struct FileNode: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let icon: String
    let assetID: String?
    var children: [FileNode]?
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

    static let notes: [ReviewNote] = [
        ReviewNote(
            id: "note-1",
            timecode: "00:03.20",
            text: "“Held breath” lands a little flat. Try a warmer read without pushing the last word.",
            author: "You",
            createdAt: "2 min ago",
            isResolved: false
        ),
        ReviewNote(
            id: "note-2",
            timecode: "00:07.10",
            text: "The pause before “By six” runs long. Tighten it by about 0.4 seconds.",
            author: "You",
            createdAt: "6 min ago",
            isResolved: false
        ),
        ReviewNote(
            id: "note-3",
            timecode: "00:10.40",
            text: "Good close. Keep this timing.",
            author: "You",
            createdAt: "8 min ago",
            isResolved: true
        )
    ]

    static let takes: [TakeVersion] = [
        TakeVersion(
            id: "take-03",
            name: "Take 03",
            status: .needsReview,
            createdAt: "Today, 21:12",
            detail: "Current · 00:12.4"
        ),
        TakeVersion(
            id: "take-02",
            name: "Take 02",
            status: .approved,
            createdAt: "Today, 20:48",
            detail: "Approved · 00:12.8"
        ),
        TakeVersion(
            id: "take-01",
            name: "Take 01",
            status: .draft,
            createdAt: "Today, 20:31",
            detail: "Archived · 00:13.1"
        )
    ]

    static let fileTree: [FileNode] = [
        FileNode(id: "root", name: "Tidewater", icon: "folder", assetID: nil, children: [
            FileNode(id: "file-script", name: "tidewater-script.md", icon: "doc.text", assetID: "script-md", children: nil),
            FileNode(id: "file-outline", name: "outline.md", icon: "doc.text", assetID: "outline-md", children: nil),
            FileNode(id: "folder-voice", name: "voice", icon: "folder", assetID: nil, children: [
                FileNode(id: "file-vo-03", name: "vo-take-03.wav", icon: "waveform", assetID: "vo-take-03", children: nil),
                FileNode(id: "file-vo-02", name: "vo-take-02.wav", icon: "waveform", assetID: "vo-take-02", children: nil)
            ]),
            FileNode(id: "folder-visuals", name: "visuals", icon: "folder", assetID: nil, children: [
                FileNode(id: "folder-stills", name: "stills", icon: "folder", assetID: "stills", children: nil),
                FileNode(id: "folder-broll", name: "b-roll", icon: "folder", assetID: "broll", children: nil)
            ]),
            FileNode(id: "folder-takes", name: "takes", icon: "folder", assetID: nil, children: [
                FileNode(id: "file-take-03", name: "take-03.mp4", icon: "film", assetID: "take-03", children: nil),
                FileNode(id: "file-take-02", name: "take-02.mp4", icon: "film", assetID: "take-02", children: nil)
            ]),
            FileNode(id: "folder-delivery", name: "delivery", icon: "folder", assetID: nil, children: [
                FileNode(id: "file-storyboard", name: "storyboard.html", icon: "globe", assetID: "storyboard-html", children: nil),
                FileNode(id: "file-render", name: "Tidewater — 1080p.mp4", icon: "shippingbox", assetID: "render-1080", children: nil)
            ])
        ])
    ]
}
