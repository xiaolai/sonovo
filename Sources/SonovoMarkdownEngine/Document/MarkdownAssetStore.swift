import CryptoKit
import Foundation

public enum MarkdownAssetError: Error, Equatable {
    case untitledDocument
    case invalidExtension
    case outsideWorkspace
    case writeFailed(String)
}

/// The result of storing an image asset.
public struct StoredAsset: Sendable, Equatable {
    /// The relative link to insert into Markdown source.
    public let path: String
    /// Whether this call created the file (false when an existing matching
    /// asset was reused).
    public let created: Bool

    public init(path: String, created: Bool) {
        self.path = path
        self.created = created
    }
}

/// Copies pasted or dropped images into a document-relative `assets/` folder.
///
/// Filenames are content-addressed, so the same bytes are written once. The
/// returned path is the relative link an editor inserts into the source.
public struct MarkdownAssetStore: Sendable {
    public init() {}

    public func store(
        imageData: Data,
        fileExtension: String,
        relativeTo documentURL: URL,
        workspaceRoot: URL
    ) throws -> String {
        try storeWithStatus(
            imageData: imageData,
            fileExtension: fileExtension,
            relativeTo: documentURL,
            workspaceRoot: workspaceRoot
        ).path
    }

    public func storeWithStatus(
        imageData: Data,
        fileExtension: String,
        relativeTo documentURL: URL,
        workspaceRoot: URL
    ) throws -> StoredAsset {
        guard documentURL.isFileURL else {
            throw MarkdownAssetError.untitledDocument
        }

        let sanitized = fileExtension
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        guard !sanitized.isEmpty, sanitized.count <= 8 else {
            throw MarkdownAssetError.invalidExtension
        }

        let hash = SHA256.hash(data: imageData)
            .map { String(format: "%02x", $0) }
            .joined()
        let filename = "image-\(hash).\(sanitized)"

        let assetDirectory = documentURL
            .deletingLastPathComponent()
            .appendingPathComponent("assets", isDirectory: true)
            .standardizedFileURL
        let root = workspaceRoot.standardizedFileURL

        guard MarkdownSecurity.contains(assetDirectory, in: root) else {
            throw MarkdownAssetError.outsideWorkspace
        }

        let destination = assetDirectory.appendingPathComponent(filename)
        let existedBefore = FileManager.default.fileExists(
            atPath: destination.path
        )
        if existedBefore {
            // The name is content-addressed, but an existing entry can still
            // be a directory, a symlink, or a file with different bytes.
            // Reuse it only when it is a regular file whose contents match;
            // otherwise rewrite it atomically.
            if matchesExistingAsset(at: destination, imageData: imageData) {
                return StoredAsset(
                    path: "assets/\(filename)",
                    created: false
                )
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: assetDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw MarkdownAssetError.writeFailed(String(describing: error))
        }

        if !existedBefore {
            // Create the content-addressed name exclusively. A plain atomic
            // write would replace anything that appeared between the check
            // above and this line, including another process's asset.
            do {
                if try PrivateFileWriter.createExclusively(
                    imageData,
                    at: destination
                ) {
                    return StoredAsset(
                        path: "assets/\(filename)",
                        created: true
                    )
                }
                if matchesExistingAsset(at: destination, imageData: imageData) {
                    return StoredAsset(
                        path: "assets/\(filename)",
                        created: false
                    )
                }
                throw MarkdownAssetError.writeFailed(
                    "asset path appeared with different contents: "
                        + destination.path
                )
            } catch let failure as PrivateFileWriter.Failure {
                throw MarkdownAssetError.writeFailed(
                    "cannot create \(destination.path): errno \(failure.code)"
                )
            }
        }

        do {
            try imageData.write(to: destination, options: .atomic)
        } catch {
            throw MarkdownAssetError.writeFailed(String(describing: error))
        }

        return StoredAsset(
            path: "assets/\(filename)",
            created: false
        )
    }

    /// Whether `url` is a regular, non-symlink file holding exactly
    /// `imageData`.
    private func matchesExistingAsset(at url: URL, imageData: Data) -> Bool {
        let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              let existing = try? Data(contentsOf: url) else {
            return false
        }
        return existing == imageData
    }

}
