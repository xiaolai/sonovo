import Foundation

/// The sample production names real documents, so those assets need real
/// files behind them. The documents ship read-only in the app bundle; the
/// first open copies them into Application Support, where the normal editor,
/// file watcher, and autosave paths can write to them.
struct SampleProjectDocuments {
    let sourceDirectory: URL
    let destinationDirectory: URL
    private let fileManager: FileManager

    init(
        sourceDirectory: URL,
        destinationDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.sourceDirectory = sourceDirectory
        self.destinationDirectory = destinationDirectory
        self.fileManager = fileManager
    }

    static func live(
        bundle: Bundle = .module,
        fileManager: FileManager = .default
    ) -> SampleProjectDocuments? {
        guard let source = bundle.url(
            forResource: "SampleProject",
            withExtension: nil
        ), let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return SampleProjectDocuments(
            sourceDirectory: source,
            destinationDirectory: support
                .appendingPathComponent("Sonovo", isDirectory: true)
                .appendingPathComponent("Sample Project", isDirectory: true),
            fileManager: fileManager
        )
    }

    /// Returns the writable copy of a sample document, copying it on first
    /// use. An existing copy is never overwritten: those edits belong to the
    /// user, and the bundled file is only the seed.
    func documentURL(named name: String) -> URL? {
        let source = sourceDirectory.appendingPathComponent(name)
        guard fileManager.isReadableFile(atPath: source.path) else {
            return nil
        }
        do {
            try fileManager.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
            let target = destinationDirectory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: target.path) {
                try fileManager.copyItem(at: source, to: target)
            }
            return target
        } catch {
            return nil
        }
    }
}
