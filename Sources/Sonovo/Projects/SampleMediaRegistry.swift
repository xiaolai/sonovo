import Foundation
import Observation

/// The Sample project has no folder scanner. Its bundled takes and the files
/// created by recording or export live in Application Support, so this small
/// registry supplies the asset rows and the synthetic Recordings stage.
@MainActor
@Observable
final class SampleMediaRegistry {
    let directory: URL
    private(set) var recordings: [ProjectAsset] = []

    private let fileManager: FileManager
    /// Bundled takes already have authored production rows. They are real
    /// files in the same directory, but not "recordings" the user made.
    private let excludedNames: Set<String>

    init(
        directory: URL,
        excludedNames: Set<String> = ["vo-take-02.wav", "vo-take-03.wav"],
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.excludedNames = excludedNames
        self.fileManager = fileManager
        refresh()
    }

    func refresh() {
        let names = (try? fileManager.contentsOfDirectory(
            atPath: directory.path
        )) ?? []
        recordings = names
            .filter { !$0.hasPrefix(".") }
            .filter {
                URL(fileURLWithPath: $0).pathExtension.lowercased() == "wav"
            }
            .filter { !excludedNames.contains($0) }
            .compactMap { name in
                asset(for: directory.appendingPathComponent(name))
            }
            .sorted {
                $0.name.localizedStandardCompare($1.name)
                    == .orderedAscending
            }
    }

    func asset(id: String) -> ProjectAsset? {
        recordings.first { $0.id == id }
    }

    func asset(for url: URL) -> ProjectAsset? {
        guard url.deletingLastPathComponent().standardizedFileURL
                == directory.standardizedFileURL,
              let values = try? url.resourceValues(
                  forKeys: [.fileSizeKey, .contentModificationDateKey]
              ) else {
            return nil
        }
        let size = Int64(values.fileSize ?? 0)
        let modified = values.contentModificationDate
        let name = url.lastPathComponent
        return ProjectAsset(
            id: "recording-\(name)",
            url: url,
            name: name,
            relativePath: name,
            kind: .audio,
            size: size,
            modified: modified,
            revision: AssetRevision(
                fileIdentifier: nil,
                size: size,
                modified: modified
            )
        )
    }

    @discardableResult
    func register(url: URL) -> ProjectAsset? {
        refresh()
        return asset(for: url)
    }

    func productionAssets() -> [ProductionAsset] {
        recordings.map { asset in
            ProductionAsset(
                id: asset.id,
                name: asset.name,
                detail: detail(for: asset),
                kind: .audio
            )
        }
    }

    func productionStage() -> ProductionStage? {
        let assets = productionAssets()
        guard !assets.isEmpty else { return nil }
        return ProductionStage(
            id: "recordings",
            title: "Recordings",
            assets: assets
        )
    }

    private func detail(for asset: ProjectAsset) -> String {
        if let audio = MediaAudioMetadata.describe(url: asset.url) {
            return audio.detail
        }
        let formatted = asset.modified?.formatted(
            date: .abbreviated,
            time: .shortened
        ) ?? "Unknown date"
        let size = ByteCountFormatter.string(
            fromByteCount: asset.size,
            countStyle: .file
        )
        return "WAV audio · \(size) · \(formatted)"
    }
}
