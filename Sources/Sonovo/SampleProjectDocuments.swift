import Foundation

enum SampleDocumentError: LocalizedError, Equatable {
    case sourceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .sourceUnavailable(name):
            "The bundled sample “\(name)” is missing or unreadable."
        }
    }
}

/// The sample production names real files, so those assets need real files
/// behind them. The samples ship read-only in the app bundle; the first open
/// copies them into Application Support, where the normal editor, media
/// player, file watcher, and autosave paths can read and write them.
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
    ///
    /// Throws with the underlying failure so the caller can say why the
    /// document could not be prepared.
    func documentURL(named name: String) throws -> URL {
        let source = sourceDirectory.appendingPathComponent(name)
        guard fileManager.isReadableFile(atPath: source.path) else {
            throw SampleDocumentError.sourceUnavailable(name)
        }
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let target = destinationDirectory.appendingPathComponent(name)
        if !fileManager.fileExists(atPath: target.path) {
            try fileManager.copyItem(at: source, to: target)
        }
        return target
    }
}
