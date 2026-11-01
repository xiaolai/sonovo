import SonovoFileIO
import SonovoDocumentSupport
import SonovoTextEngine
import SonovoDomainTypes
import SonovoFeatureAPI
import Foundation
import Observation

package enum MDXDocumentError: Error, LocalizedError, Equatable {
    case outsideProject
    case unsupportedExtension(String)
    case unreadable(String)
    case tooLarge(bytes: Int, limit: Int)
    case notUTF8
    case changedOnDisk
    case saveFailed(String)

    package var errorDescription: String? {
        switch self {
        case .outsideProject:
            "The document is outside the project folder."
        case .unsupportedExtension(let name):
            "Only .mdx and .jsx files open in the MDX workspace: \(name)"
        case .unreadable(let detail):
            "The document could not be read: \(detail)"
        case .tooLarge(let bytes, let limit):
            "The document is \(bytes) bytes; the limit is \(limit)."
        case .notUTF8:
            "The document is not UTF-8 text."
        case .changedOnDisk:
            "The file changed on disk since it was opened. "
                + "Reopen it before saving."
        case .saveFailed(let detail):
            "The document could not be saved: \(detail)"
        }
    }
}

/// One `.mdx` or `.jsx` document. The source is canonical: the editor writes
/// this text to the file, and the preview only reads it. Nothing a compile or
/// a web view does changes `source`.
@MainActor
@Observable
package final class MDXDocument: Identifiable {
    package static let maxSourceLines = 100_000
    package static let maxBytes = 4 * 1024 * 1024

    package let id = UUID()
    package let fileURL: URL
    /// The backing URL's project-relative POSIX path, the id every module in
    /// the compile uses.
    package let relativePath: String

    package private(set) var savedSource: String
    /// The exact bytes last read from or written to the file. A save is a
    /// compare-and-swap against these bytes, so an external edit is never
    /// silently overwritten.
    private var diskBytes: Data
    package var source: String {
        didSet {
            // Byte comparison: canonically equivalent Unicode (composed vs
            // decomposed) is a different file, even though String == says
            // otherwise.
            if !source.utf8.elementsEqual(oldValue.utf8) {
                revision &+= 1
            }
        }
    }

    /// Bumped on every text change. A compile that returns for an older
    /// revision is discarded instead of replacing newer output.
    package private(set) var revision: UInt64 = 0

    package var isDirty: Bool { !source.utf8.elementsEqual(savedSource.utf8) }
    package var displayName: String { fileURL.lastPathComponent }

    private init(
        url: URL,
        relativePath: String,
        source: String,
        diskBytes: Data
    ) {
        fileURL = url
        self.relativePath = relativePath
        savedSource = source
        self.source = source
        self.diskBytes = diskBytes
    }

    package static func load(url: URL, projectRoot: URL) throws -> MDXDocument {
        let canonical = FilePathPolicy.canonical(url)
        let ext = canonical.pathExtension.lowercased()
        guard ext == "mdx" || ext == "jsx" else {
            throw MDXDocumentError.unsupportedExtension(
                canonical.lastPathComponent
            )
        }
        let root = FilePathPolicy.canonical(projectRoot)
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard canonical.path.hasPrefix(rootPath) else {
            throw MDXDocumentError.outsideProject
        }
        let relative = String(canonical.path.dropFirst(rootPath.count))
        guard !relative.isEmpty else {
            throw MDXDocumentError.outsideProject
        }
        let data: Data
        do {
            // Bounded before allocation: an oversized file is refused
            // without mapping it into memory.
            data = try BoundedFileReader.read(
                canonical,
                maximumBytes: maxBytes, maximumLines: maxSourceLines
            )
        } catch let error as FileReadError {
            if case .fileTooLarge(let bytes) = error {
                throw MDXDocumentError.tooLarge(bytes: bytes, limit: maxBytes)
            }
            if case .tooManyLines(let count) = error {
                // Preserve the pre-extraction read-failure message.
                throw MDXDocumentError.unreadable("The Markdown file has more than \(count) lines; the reading limit is \(maxSourceLines) lines.")
            }
            throw MDXDocumentError.unreadable(error.localizedDescription)
        } catch {
            throw MDXDocumentError.unreadable(error.localizedDescription)
        }
        guard data.count <= maxBytes else {
            throw MDXDocumentError.tooLarge(
                bytes: data.count,
                limit: maxBytes
            )
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw MDXDocumentError.notUTF8
        }
        return MDXDocument(
            url: canonical,
            relativePath: relative,
            source: source,
            diskBytes: data
        )
    }

    /// Writes the editor's text to the canonical file. The preview never
    /// calls this; only an explicit Save does.
    ///
    /// The write is a compare-and-swap against the bytes this document last
    /// read or wrote, performed by the same store every Markdown save uses:
    /// an external edit is refused, never silently overwritten, and the
    /// replacement is verified rather than trusting a bare atomic rename.
    package func save() throws {
        let data = Data(source.utf8)
        guard data.count <= Self.maxBytes else {
            throw MDXDocumentError.tooLarge(
                bytes: data.count,
                limit: Self.maxBytes
            )
        }
        let request = SaveRequest(
            documentID: id,
            identityGeneration: 0,
            sourceRevision: revision,
            destination: fileURL,
            expectedDisk: DiskSnapshot(bytes: diskBytes),
            data: data,
            mode: .explicitOverwrite,
            maximumReplacedBytes: Self.maxBytes
        )
        let outcome: SaveOutcome
        do {
            outcome = try AtomicFileStore().save(request)
        } catch let error as SaveError {
            if case .diskChanged = error {
                throw MDXDocumentError.changedOnDisk
            }
            throw MDXDocumentError.saveFailed(String(describing: error))
        } catch {
            throw MDXDocumentError.saveFailed(error.localizedDescription)
        }
        diskBytes = outcome.snapshot.bytes
        savedSource = source
    }
}
