import Foundation

/// Identity of one revision of a file. The viewer keys on this, not on the
/// path alone: agents overwrite outputs, and a stale URL must not keep showing
/// the previous content.
struct AssetRevision: Hashable, Sendable {
    let fileIdentifier: String?
    let size: Int64
    let modified: Date?

    static let empty = AssetRevision(
        fileIdentifier: nil,
        size: 0,
        modified: nil
    )

    var token: String {
        let identifier = fileIdentifier ?? "-"
        let stamp = modified?.timeIntervalSince1970 ?? 0
        return "\(identifier)|\(size)|\(stamp)"
    }
}

/// One file a project can read. The canonical path is the identity; the
/// asset carries the minimum metadata the browser and inspector need.
struct ProjectAsset: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let relativePath: String
    let kind: AssetKind
    let size: Int64
    let modified: Date?
    let revision: AssetRevision

    var fileExtension: String { url.pathExtension.lowercased() }

    var detail: String {
        var parts = [kind.projectGroup.title]
        if size > 0 {
            parts.append(
                ByteCountFormatter.string(
                    fromByteCount: size,
                    countStyle: .file
                )
            )
        }
        if let modified {
            parts.append(
                modified.formatted(date: .abbreviated, time: .shortened)
            )
        }
        return parts.joined(separator: " · ")
    }
}

struct ProjectGroupDescriptor: Hashable, Sendable {
    let id: String
    let title: String
    let order: Int
}

struct ProjectAssetGroup: Identifiable, Hashable, Sendable {
    let descriptor: ProjectGroupDescriptor
    let assets: [ProjectAsset]

    var id: String { descriptor.id }
    var title: String { descriptor.title }
}

extension AssetKind {
    var projectGroup: ProjectGroupDescriptor {
        switch self {
        case .script, .document:
            ProjectGroupDescriptor(
                id: "documents",
                title: "Documents",
                order: 0
            )
        case .subtitle:
            ProjectGroupDescriptor(
                id: "subtitles",
                title: "Subtitles",
                order: 2
            )
        case .code:
            ProjectGroupDescriptor(
                id: "code",
                title: "Code",
                order: 1
            )
        case .audio:
            ProjectGroupDescriptor(
                id: "audio",
                title: "Audio",
                order: 3
            )
        case .video:
            ProjectGroupDescriptor(
                id: "video",
                title: "Video",
                order: 4
            )
        case .stills, .image:
            ProjectGroupDescriptor(
                id: "images",
                title: "Images",
                order: 5
            )
        case .model3d:
            ProjectGroupDescriptor(
                id: "models",
                title: "3D",
                order: 6
            )
        case .html:
            ProjectGroupDescriptor(
                id: "web",
                title: "Web",
                order: 7
            )
        case .archive:
            ProjectGroupDescriptor(
                id: "archives",
                title: "Archives",
                order: 8
            )
        case .delivery, .other:
            ProjectGroupDescriptor(
                id: "other",
                title: "Other",
                order: 9
            )
        }
    }
}
