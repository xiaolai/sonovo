import Foundation

package enum AssetKind: String, Hashable, Sendable {
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
    case timeline
    case mdx

    package var icon: String {
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
        case .timeline: "rectangle.3.group"
        case .mdx: "curlybraces.square"
        }
    }

    package var tabIcon: String {
        switch self {
        case .stills: "photo"
        case .model3d: "cube"
        case .html: "globe"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .timeline: "rectangle.3.group"
        case .mdx: "curlybraces.square"
        default: icon
        }
    }

    package var workspaceTitle: String {
        switch self {
        case .script: "Script"
        case .subtitle: "Subtitles"
        case .model3d: "3D"
        case .timeline: "Timeline"
        case .mdx: "MDX"
        default: "Workspace"
        }
    }
}
