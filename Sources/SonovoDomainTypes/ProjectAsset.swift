import SonovoFileIO
import Foundation

/// Identity of one revision of a file. The viewer keys on this, not on the
/// path alone: agents overwrite outputs, and a stale URL must not keep showing
/// the previous content.
package struct AssetRevision: Hashable, Sendable {

    package init(
        fileIdentifier: String?,
        size: Int64,
        modified: Date?,
        observedMetadata: FileMetadataSnapshot? = nil
    ) {
        self.fileIdentifier = fileIdentifier
        self.size = size
        self.modified = modified
        self.observedMetadata = observedMetadata
    }

    package let fileIdentifier: String?
    package let size: Int64
    package let modified: Date?

    /// Fresh evidence for strict media validation. It is deliberately absent
    /// from persisted tokens, equality and hashing: inode metadata changes must
    /// not rebuild a viewer or invalidate an edit decision.
    package let observedMetadata: FileMetadataSnapshot?

    /// Preserve the released URL-resource identity namespace and timestamp
    /// representation. Fresh URLs avoid reusing Foundation's resource cache.
    package static func read(of url: URL) -> AssetRevision? {
        var fresh = URL(fileURLWithPath: url.path)
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: [
            .fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey
        ]) else { return nil }
        return AssetRevision(fileIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
            size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate,
            observedMetadata: FileMetadataSnapshot.read(fresh))
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fileIdentifier == rhs.fileIdentifier && lhs.size == rhs.size && lhs.modified == rhs.modified
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(fileIdentifier)
        hasher.combine(size)
        hasher.combine(modified)
    }

    package static let empty = AssetRevision(
        fileIdentifier: nil,
        size: 0,
        modified: nil
    )

    package var token: String {
        let identifier = fileIdentifier ?? "-"
        let stamp = modified?.timeIntervalSince1970 ?? 0
        return "\(identifier)|\(size)|\(stamp)"
    }
}

/// One file a project can read. The canonical path is the identity; the
/// asset carries the minimum metadata the browser and inspector need.
package struct ProjectAsset: Identifiable, Hashable, Sendable {

    package init(
        id: String,
        url: URL,
        name: String,
        relativePath: String,
        kind: AssetKind,
        size: Int64,
        modified: Date?,
        revision: AssetRevision
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.relativePath = relativePath
        self.kind = kind
        self.size = size
        self.modified = modified
        self.revision = revision
    }

    package let id: String
    package let url: URL
    package let name: String
    package let relativePath: String
    package let kind: AssetKind
    package let size: Int64
    package let modified: Date?
    package let revision: AssetRevision

    package var fileExtension: String { url.pathExtension.lowercased() }

    package var detail: String {
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

package struct ProjectGroupDescriptor: Hashable, Sendable {

    package init(
        id: String,
        title: String,
        order: Int
    ) {
        self.id = id
        self.title = title
        self.order = order
    }

    package let id: String
    package let title: String
    package let order: Int
}

package struct ProjectAssetGroup: Identifiable, Hashable, Sendable {

    package init(
        descriptor: ProjectGroupDescriptor,
        assets: [ProjectAsset]
    ) {
        self.descriptor = descriptor
        self.assets = assets
    }

    package let descriptor: ProjectGroupDescriptor
    package let assets: [ProjectAsset]

    package var id: String { descriptor.id }
    package var title: String { descriptor.title }
}

extension AssetKind {
    package var projectGroup: ProjectGroupDescriptor {
        switch self {
        case .script, .document, .timeline:
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
        case .code, .mdx:
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
