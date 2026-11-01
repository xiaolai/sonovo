import SonovoFileIO
import SonovoDomainTypes
import Foundation

package struct ProjectScanResult: Sendable {
    package init(root: URL, assets: [ProjectAsset], groups: [ProjectAssetGroup], truncated: Bool,
         visitedEntries: Int, isPartial: Bool) {
        self.root = root; self.assets = assets; self.groups = groups
        self.truncated = truncated; self.visitedEntries = visitedEntries; self.isPartial = isPartial
    }
    package let root: URL
    package let assets: [ProjectAsset]
    package let groups: [ProjectAssetGroup]
    package let truncated: Bool
    package let visitedEntries: Int
    /// A directory could not be read. The asset list is incomplete, so the
    /// project must keep its previous index rather than treating absent
    /// entries as deleted.
    package let isPartial: Bool
}

/// The scan boundary, so recovery tests can gate a scan and prove that
/// `Project.load()` waits for the completed snapshot.
package protocol ProjectScanning: Sendable {
    func scan(root: URL) -> ProjectScanResult
}

/// Pure, bounded folder scan. It never follows directory symlinks, resolves
/// file symlinks and requires them to stay inside the root, and stops on a
/// visited-entry cap so a tree of unsupported files cannot outrun the asset
/// cap.
package struct ProjectScanner: ProjectScanning {
    package struct Limits: Sendable {
        package init(maximumDepth: Int = 12, maximumAssets: Int = 20_000, maximumVisitedEntries: Int = 200_000) {
            self.maximumDepth = maximumDepth; self.maximumAssets = maximumAssets
            self.maximumVisitedEntries = maximumVisitedEntries
        }
        package var maximumDepth = 12
        package var maximumAssets = 20_000
        package var maximumVisitedEntries = 200_000
    }

    package var limits: Limits
    private let readRevision: @Sendable (URL) -> AssetRevision?
    package let catalogue: DocumentRecognitionCatalogue
    package init(catalogue: DocumentRecognitionCatalogue, limits: Limits = Limits(),
                 readRevision: @escaping @Sendable (URL) -> AssetRevision? = { AssetRevision.read(of: $0) }) {
        self.catalogue = catalogue
        self.readRevision = readRevision
        self.limits = limits
    }

    package static let ignoredDirectories = ProjectPathPolicy.ignoredDirectories

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isPackageKey, .fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey
    ]

    package static let markdownExtensions: Set<String> = ["md", "markdown"]
    package static let mdxExtensions: Set<String> = ["mdx", "jsx"]

    package func scan(root: URL) -> ProjectScanResult {
        let canonicalRoot = FilePathPolicy.canonical(root)
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
                      let kind = catalogue.resolve(resolved.lastPathComponent)?.kind else {
                    continue
                }

                let path = resolved.path
                guard seenPaths.insert(path).inserted else { continue }
                // Failure of the fresh revision probe is not evidence that this
                // directory is incomplete. Preserve the enumerated file using
                // its known resource values, as the released scanner did.
                let revision = readRevision(resolved) ?? AssetRevision(
                    fileIdentifier: resolvedValues?.fileResourceIdentifier.map { String(describing: $0) },
                    size: Int64(resolvedValues?.fileSize ?? 0), modified: resolvedValues?.contentModificationDate)
                let size = revision.size
                let modified = revision.modified
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
                        revision: revision
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

    package static func groups(from assets: [ProjectAsset]) -> [ProjectAssetGroup] {
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
