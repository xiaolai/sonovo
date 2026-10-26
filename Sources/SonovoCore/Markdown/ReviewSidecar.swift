import CryptoKit
import Darwin
import Foundation

/// Where the sidecar stood when a caller last read it.
///
/// Saving is compare-and-swap on this value: a sidecar that appeared,
/// disappeared, or changed since the caller looked is an external change, not
/// something to overwrite silently.
public struct ReviewSidecarState: Equatable, Sendable {
    public let exists: Bool
    /// SHA-256 of the sidecar's exact bytes, `nil` when it does not exist.
    public let fingerprint: String?

    public static let missing = ReviewSidecarState(
        exists: false,
        fingerprint: nil
    )

    public init(exists: Bool, fingerprint: String?) {
        self.exists = exists
        self.fingerprint = fingerprint
    }
}

public enum ReviewSidecarError: Error, Equatable, Sendable {
    /// The file exists but is not a sidecar this build can read. It is never
    /// overwritten: the comments in it are not recoverable from source.
    case corrupt(String)
    case unreadable(String)
    /// A newer sidecar format. Fail closed rather than drop fields.
    case unsupportedVersion(Int)
    /// Another writer changed the sidecar since this caller loaded it.
    case externalChange
    case writeFailed(String)
}

/// One sidecar read: the decoded content plus the state to pass back on save.
public struct ReviewSidecarLoad: Equatable, Sendable {
    public let document: ReviewDocument
    public let state: ReviewSidecarState

    public init(document: ReviewDocument, state: ReviewSidecarState) {
        self.document = document
        self.state = state
    }
}

/// Reads and writes the `.name.review.json` sidecar beside a document.
///
/// The document itself is never touched. Writes are atomic and gated on the
/// state the caller last observed, so two app instances cannot silently
/// overwrite each other's threads. The JSON is pretty-printed with sorted
/// keys and ISO 8601 dates, so a person or a CLI can read and diff it.
public enum ReviewSidecar {
    /// A sidecar is comment data, not a document; anything above this is
    /// refused before decoding so a malformed file cannot exhaust memory.
    public static let maximumBytes = 4 * 1024 * 1024

    /// Loads the sidecar for `documentURL`, or an empty review document when
    /// none exists. `documentIdentity` is recorded for a sidecar that has to
    /// be created, and is replaced by the caller on every save.
    public static func load(
        for documentURL: URL,
        documentIdentity: String
    ) throws -> ReviewSidecarLoad {
        let url = ReviewAnchorResolver.sidecarURL(for: documentURL)
        let data: Data
        do {
            data = try readBounded(url)
        } catch let error as ReviewSidecarError {
            throw error
        } catch {
            if isMissingFile(error) {
                return ReviewSidecarLoad(
                    document: ReviewDocument(
                        documentName: documentURL.lastPathComponent,
                        documentIdentity: documentIdentity
                    ),
                    state: .missing
                )
            }
            throw ReviewSidecarError.unreadable(
                "\(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
        let document: ReviewDocument
        do {
            document = try ReviewDocument.decoded(data)
        } catch {
            throw ReviewSidecarError.corrupt(url.lastPathComponent)
        }
        guard document.version == ReviewDocument.currentVersion else {
            throw ReviewSidecarError.unsupportedVersion(document.version)
        }
        return ReviewSidecarLoad(
            document: document,
            state: ReviewSidecarState(
                exists: true,
                fingerprint: fingerprint(of: data)
            )
        )
    }

    /// Writes `document` atomically, but only when the sidecar still matches
    /// `state`. Returns the state the caller should use for the next save.
    ///
    /// The comparison and the replacement run under one cross-process lock:
    /// two app instances saving at the same moment would otherwise both pass
    /// the fingerprint check and the second would silently discard the
    /// first's threads. The lock lives in a separate file because the
    /// sidecar itself is replaced by an atomic rename — a lock held on its
    /// own descriptor would travel with the old inode, not the new one.
    @discardableResult
    public static func save(
        _ document: ReviewDocument,
        for documentURL: URL,
        ifUnchangedSince state: ReviewSidecarState
    ) throws -> ReviewSidecarState {
        let url = ReviewAnchorResolver.sidecarURL(for: documentURL)
        let data: Data
        do {
            data = try document.encoded()
        } catch {
            throw ReviewSidecarError.writeFailed(
                "encode: \(error.localizedDescription)"
            )
        }
        guard data.count <= maximumBytes else {
            throw ReviewSidecarError.writeFailed("sidecar exceeds size limit")
        }
        do {
            try withExclusiveLock(at: lockURL(for: url)) {
                let current = try currentState(at: url)
                guard current == state else {
                    throw ReviewSidecarError.externalChange
                }
                try data.write(to: url, options: [.atomic])
            }
        } catch let error as ReviewSidecarError {
            throw error
        } catch {
            throw ReviewSidecarError.writeFailed(
                "\(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
        return ReviewSidecarState(
            exists: true,
            fingerprint: fingerprint(of: data)
        )
    }

    /// The sidecar's state as it stands on disk, for an explicit overwrite.
    public static func currentState(at url: URL) throws -> ReviewSidecarState {
        do {
            let data = try readBounded(url)
            return ReviewSidecarState(
                exists: true,
                fingerprint: fingerprint(of: data)
            )
        } catch let error as ReviewSidecarError {
            throw error
        } catch {
            if isMissingFile(error) { return .missing }
            throw ReviewSidecarError.unreadable(
                "\(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    public static func currentState(
        for documentURL: URL
    ) throws -> ReviewSidecarState {
        try currentState(at: ReviewAnchorResolver.sidecarURL(for: documentURL))
    }

    public static func fingerprint(of data: Data) -> String {
        ReviewDigest.hex(data)
    }

    private static func readBounded(_ url: URL) throws -> Data {
        // One bounded read rather than a stat followed by an unbounded
        // `Data(contentsOf:)`: the file can grow or be a link between the
        // two, which would allocate the whole thing before the size check.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw ReviewSidecarError.corrupt(url.lastPathComponent)
        }
        return data
    }

    /// `.<name>.review.json.lock` beside the sidecar.
    static func lockURL(for sidecarURL: URL) -> URL {
        sidecarURL.appendingPathExtension("lock")
    }

    /// Runs `body` while holding an exclusive `flock` that every process
    /// uses for this sidecar. The descriptor's `close` releases the lock,
    /// including on an abnormal exit.
    static func withExclusiveLock<T>(
        at url: URL,
        _ body: () throws -> T
    ) throws -> T {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_CREAT | O_RDWR, 0o600) } ?? -1
        }
        guard descriptor >= 0 else {
            throw ReviewSidecarError.writeFailed(
                "lock: \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw ReviewSidecarError.writeFailed(
                    "lock: \(String(cString: strerror(errno)))"
                )
            }
        }
        return try body()
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSFileReadNoSuchFileError
                || nsError.code == NSFileNoSuchFileError)
    }
}

enum ReviewDigest {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
