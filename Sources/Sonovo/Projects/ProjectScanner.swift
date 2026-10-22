import Foundation
import SonovoCore

struct ProjectScanResult: Sendable {
    let root: URL
    let assets: [ProjectAsset]
    let groups: [ProjectAssetGroup]
    let truncated: Bool
    let visitedEntries: Int
    /// A directory could not be read. The asset list is incomplete, so the
    /// project must keep its previous index rather than treating absent
    /// entries as deleted.
    let isPartial: Bool
}

/// Pure, bounded folder scan. It never follows directory symlinks, resolves
/// file symlinks and requires them to stay inside the root, and stops on a
/// visited-entry cap so a tree of unsupported files cannot outrun the asset
/// cap.
struct ProjectScanner: Sendable {
    struct Limits: Sendable {
        var maximumDepth = 12
        var maximumAssets = 20_000
        var maximumVisitedEntries = 200_000
    }

    var limits = Limits()

    static let ignoredDirectories: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", "DerivedData", ".build",
        "Caches", ".cache", ".Trash"
    ]

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .fileResourceIdentifierKey
    ]

    private static let markdownExtensions: Set<String> = ["md", "markdown"]
    private static let documentExtensions: Set<String> = [
        "pdf", "docx", "rtf", "odt", "pages", "key", "pptx", "xlsx",
        "csv", "tsv", "fountain", "fdx", "epub",
        "otio", "edl", "fcpxml"
    ]
    private static let audioExtensions: Set<String> = [
        "wav", "aif", "aiff", "mp3", "m4a", "aac", "flac", "ogg", "opus"
    ]
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm", "mkv", "mxf", "avi"
    ]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "heic", "heif", "tif",
        "tiff", "webp", "avif", "dng", "cr3", "arw", "nef", "exr",
        "hdr", "psd", "psb", "ai", "eps", "svg"
    ]
    private static let webExtensions: Set<String> = ["html", "htm"]
    private static let archiveExtensions: Set<String> = [
        "zip", "mhl", "ascmhl"
    ]
    private static let modelExtensions: Set<String> = Set(
        Model3DFormat.allCases.map(\.rawValue)
    )
    private static let subtitleExtensions: Set<String> = Set(
        SubtitleFormat.allCases.map(\.rawValue)
    )

    func scan(root: URL) -> ProjectScanResult {
        let canonicalRoot = MarkdownSecurity.canonical(root)
        let rootPath = canonicalRoot.path.hasSuffix("/")
            ? canonicalRoot.path
            : canonicalRoot.path + "/"

        var assets: [ProjectAsset] = []
        var seenPaths: Set<String> = []
        var visited = 0
        var truncated = false
        var isPartial = false

        // Walk directories in a fixed order. `FileManager.enumerator` yields
        // entries in an unspecified order, so which assets survive the
        // visited and asset caps would change between scans. Sorting each
        // directory's names before pushing it makes both the index and the
        // subset deterministic. Only one directory's names are held at a
        // time; metadata is read per entry after the cap check.
        var stack: [(url: URL, depth: Int)] = [(canonicalRoot, 0)]
        scanLoop: while let directory = stack.popLast() {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(
                    atPath: directory.url.path
                )
            } catch {
                // A directory that cannot be read makes the index partial;
                // reconciliation must not treat its files as deleted.
                isPartial = true
                continue
            }
            let sorted = names.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            for name in sorted where !name.hasPrefix(".") {
                let entry = directory.url.appendingPathComponent(name)
                visited += 1
                if visited > limits.maximumVisitedEntries {
                    truncated = true
                    break scanLoop
                }
                guard let values = try? entry.resourceValues(
                    forKeys: Self.resourceKeys
                ) else {
                    // A metadata failure is not proof the file is gone.
                    // Mark the scan partial so reconciliation does not
                    // treat the omission as a deletion.
                    isPartial = true
                    continue
                }
                let isDirectory = values.isDirectory == true
                let isSymbolicLink = values.isSymbolicLink == true

                if isDirectory {
                    if isSymbolicLink {
                        continue
                    }
                    if values.isPackage == true {
                        continue
                    }
                    if Self.ignoredDirectories.contains(entry.lastPathComponent) {
                        continue
                    }
                    let childDepth = directory.depth + 1
                    if childDepth >= limits.maximumDepth {
                        truncated = true
                        continue
                    }
                    stack.append((entry, childDepth))
                    continue
                }

                guard values.isRegularFile == true || isSymbolicLink else {
                    continue
                }

                let resolved = entry.resolvingSymlinksInPath()
                    .standardizedFileURL
                guard resolved.path.hasPrefix(rootPath) else { continue }
                let resolvedValues: URLResourceValues?
                if isSymbolicLink {
                    guard let target = try? resolved.resourceValues(
                        forKeys: Self.resourceKeys
                    ) else {
                        isPartial = true
                        continue
                    }
                    resolvedValues = target
                } else {
                    resolvedValues = values
                }
                guard resolvedValues?.isRegularFile == true,
                      let kind = Self.kind(
                        forFilename: resolved.lastPathComponent
                      ) else {
                    continue
                }

                let path = resolved.path
                guard seenPaths.insert(path).inserted else { continue }
                let size = Int64(resolvedValues?.fileSize ?? 0)
                let modified = resolvedValues?.contentModificationDate
                let identifier = resolvedValues?.fileResourceIdentifier.map {
                    String(describing: $0)
                }
                assets.append(
                    ProjectAsset(
                        id: path,
                        url: resolved,
                        name: resolved.lastPathComponent,
                        relativePath: String(
                            path.dropFirst(rootPath.count)
                        ),
                        kind: kind,
                        size: size,
                        modified: modified,
                        revision: AssetRevision(
                            fileIdentifier: identifier,
                            size: size,
                            modified: modified
                        )
                    )
                )
                if assets.count >= limits.maximumAssets {
                    truncated = true
                    break scanLoop
                }
            }
        }

        assets.sort {
            $0.relativePath.localizedStandardCompare($1.relativePath)
                == .orderedAscending
        }

        return ProjectScanResult(
            root: canonicalRoot,
            assets: assets,
            groups: Self.groups(from: assets),
            truncated: truncated,
            visitedEntries: visited,
            isPartial: isPartial
        )
    }

    static func kind(forExtension fileExtension: String) -> AssetKind? {
        let ext = fileExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        if markdownExtensions.contains(ext) { return .script }
        if subtitleExtensions.contains(ext) { return .subtitle }
        if modelExtensions.contains(ext) { return .model3d }
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        if imageExtensions.contains(ext) { return .image }
        if webExtensions.contains(ext) { return .html }
        if archiveExtensions.contains(ext) { return .archive }
        if documentExtensions.contains(ext) { return .document }
        if CodeLanguage.isCodeExtension(ext) { return .code }
        return nil
    }

    /// Classification for one visible filename. Special names such as
    /// `Makefile` and `Dockerfile` are code without an extension.
    static func kind(forFilename name: String) -> AssetKind? {
        if CodeLanguage.language(forFilename: name) != nil {
            // The Markdown, subtitle, model, and web families keep their own
            // dedicated viewers; `CodeLanguage` never claims those
            // extensions.
            return .code
        }
        return kind(forExtension: (name as NSString).pathExtension)
    }

    static func groups(from assets: [ProjectAsset]) -> [ProjectAssetGroup] {
        let grouped = Dictionary(grouping: assets) { $0.kind.projectGroup }
        return grouped
            .map { descriptor, members in
                ProjectAssetGroup(
                    descriptor: descriptor,
                    assets: members.sorted {
                        $0.name.localizedStandardCompare($1.name)
                            == .orderedAscending
                    }
                )
            }
            .sorted { $0.descriptor.order < $1.descriptor.order }
    }
}
