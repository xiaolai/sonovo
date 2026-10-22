import Darwin
import Foundation
import SonovoCore

/// Why a file cannot be edited even though it can be shown.
enum CodeReadOnlyReason: Equatable, Sendable {
    case size(byteCount: Int)
    case mixedLineEndings
    case loneCarriageReturn
    case permissions

    var explanation: String {
        switch self {
        case .size(let byteCount):
            let formatted = ByteCountFormatter.string(
                fromByteCount: Int64(byteCount),
                countStyle: .file
            )
            return "Read-only: \(formatted) is above the 2 MB editing limit."
        case .mixedLineEndings:
            return "Read-only: this file mixes line endings."
        case .loneCarriageReturn:
            return "Read-only: this file contains a lone carriage return."
        case .permissions:
            return "Read-only: this file or its folder is not writable."
        }
    }
}

/// Why a file cannot be read or shown as text.
enum CodeRefusal: Equatable, Sendable {
    case tooLarge(byteCount: Int64)
    case binary
    case unsupportedEncoding(String)
    case unreadable(String)

    var explanation: String {
        switch self {
        case .tooLarge(let byteCount):
            let formatted = ByteCountFormatter.string(
                fromByteCount: byteCount,
                countStyle: .file
            )
            return "Not opened: \(formatted) is above the 8 MB reading limit."
        case .binary:
            return "Not opened: this file is binary."
        case .unsupportedEncoding(let name):
            return "Not opened: \(name) is not supported in this viewer."
        case .unreadable(let detail):
            return "Not opened: \(detail)."
        }
    }
}

/// The bytes and decoded text of one bounded code read.
struct CodeFileRead: Sendable {
    let url: URL
    let bytes: Data
    let snapshot: DiskSnapshot
    let contents: MarkdownFileContents
    let hasLoneCarriageReturn: Bool

    var byteCount: Int { bytes.count }

    var isEditableSize: Bool {
        byteCount <= CodeLimits.editableBytes
    }

    var readOnlyReason: CodeReadOnlyReason? {
        if !isEditableSize {
            return .size(byteCount: byteCount)
        }
        if contents.hadMixedLineEndings {
            return .mixedLineEndings
        }
        if hasLoneCarriageReturn {
            return .loneCarriageReturn
        }
        return nil
    }
}

enum CodeFileReadOutcome: Sendable {
    case loaded(CodeFileRead)
    case refused(CodeRefusal)
}

/// The decoded text of already-read bytes, under the same rules as `read`.
enum CodeDecodeOutcome: Sendable {
    case text(MarkdownFileContents)
    case refused(CodeRefusal)
}

/// The bytes of a path that is inspected without decoding: a Save As
/// destination or a conflict artifact.
enum CodeBoundedData: Sendable {
    case absent
    case data(Data)
    case tooLarge(byteCount: Int64)
    case notRegular
}

/// Reads code files with a bounded allocation.
///
/// The reader never reads more than `maximumBytes + 1`. A file that grows
/// during the read is cut at the cap and reported as too large, so a partially
/// read file is never decoded or applied.
struct CodeFileReader: Sendable {
    var maximumBytes: Int = CodeLimits.maximumReadBytes

    func read(url: URL) throws -> CodeFileReadOutcome {
        // A missing file is a deletion, not an unsupported type; callers
        // distinguish it from a refusal.
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        // Open non-blocking and validate the opened descriptor. A separate
        // check followed by an open could be swapped for a FIFO in between,
        // and opening that FIFO would block indefinitely.
        guard let handle = try Self.openRegularFile(url) else {
            return .refused(.unreadable("this is not a regular file"))
        }
        defer { try? handle.close() }

        let data = try readBoundedBytes(handle, cap: maximumBytes)

        if data.count > maximumBytes {
            let reportedSize = (try? url.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize).map(Int64.init) ?? Int64(data.count)
            return .refused(
                .tooLarge(byteCount: max(reportedSize, Int64(data.count)))
            )
        }

        let contents: MarkdownFileContents
        switch Self.decodeBounded(data) {
        case .text(let decoded):
            contents = decoded
        case .refused(let refusal):
            return .refused(refusal)
        }

        return .loaded(
            CodeFileRead(
                url: url,
                bytes: data,
                snapshot: DiskSnapshot(bytes: data),
                contents: contents,
                hasLoneCarriageReturn: Self.hasLoneCarriageReturn(data)
            )
        )
    }

    /// Reads the exact bytes for a change check, bounded the same way.
    func readSnapshot(url: URL) throws -> CodeFileReadOutcome {
        try read(url: url)
    }

    /// Reads only the bytes, for a path that must not be decoded (a Save As
    /// destination or a displaced conflict artifact). Never allocates more
    /// than the cap plus one.
    func boundedData(
        at url: URL,
        maximumBytes: Int? = nil
    ) throws -> CodeBoundedData {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .absent
        }
        guard let handle = try Self.openRegularFile(url) else {
            return .notRegular
        }
        defer { try? handle.close() }
        let cap = maximumBytes ?? self.maximumBytes
        let data = try readBoundedBytes(handle, cap: cap)
        if data.count > cap {
            let reported = (try? url.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize).map(Int64.init) ?? Int64(data.count)
            return .tooLarge(byteCount: max(reported, Int64(data.count)))
        }
        return .data(data)
    }

    /// The one bounded read loop: at most `cap + 1` bytes are allocated.
    private func readBoundedBytes(
        _ handle: FileHandle,
        cap: Int
    ) throws -> Data {
        var data = Data()
        let limit = cap + 1
        while data.count < limit {
            let remaining = limit - data.count
            let chunk = try handle.read(
                upToCount: min(CodeLimits.readChunkBytes, remaining)
            )
            guard let chunk, !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }

    /// Decodes bytes that were already read within the cap, under the same
    /// rules as `read`: a refused byte-order mark wins, then invalid UTF-8,
    /// then a NUL-bearing but otherwise valid UTF-8 file is binary. Used for
    /// conflict bytes, so a reload can never install text the reader would
    /// have refused to open.
    static func decodeBounded(_ data: Data) -> CodeDecodeOutcome {
        if let encoding = byteOrderMark(in: data) {
            return .refused(.unsupportedEncoding(encoding))
        }
        guard let contents = try? MarkdownEncoding.decode(data) else {
            if data.contains(0) {
                return .refused(.binary)
            }
            return .refused(.unsupportedEncoding("this encoding"))
        }
        // Encoding is decided before the binary test: UTF-16 carries NUL
        // bytes but must be reported as an encoding, not as binary. A valid
        // UTF-8 file that still contains NUL is binary.
        if data.contains(0) {
            return .refused(.binary)
        }
        return .text(contents)
    }

    /// Opens a regular file without blocking, then validates the opened
    /// descriptor. `stat` follows a symlink, so a link to a regular file is
    /// accepted and a directory, FIFO, socket, or device is refused.
    private static func openRegularFile(_ url: URL) throws -> FileHandle? {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return nil
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            return nil
        }
        return FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
    }

    /// The byte-order mark, when the bytes start with one this viewer cannot
    /// decode. UTF-32 is checked first: its LE mark begins with the UTF-16 LE
    /// mark.
    private static func byteOrderMark(in data: Data) -> String? {
        let prefix = [UInt8](data.prefix(4))
        if prefix.count >= 4, prefix[0] == 0xFF, prefix[1] == 0xFE,
           prefix[2] == 0x00, prefix[3] == 0x00 {
            return "UTF-32 LE"
        }
        if prefix.count >= 4, prefix[0] == 0x00, prefix[1] == 0x00,
           prefix[2] == 0xFE, prefix[3] == 0xFF {
            return "UTF-32 BE"
        }
        if prefix.count >= 2, prefix[0] == 0xFF, prefix[1] == 0xFE {
            return "UTF-16 LE"
        }
        if prefix.count >= 2, prefix[0] == 0xFE, prefix[1] == 0xFF {
            return "UTF-16 BE"
        }
        return nil
    }

    /// A carriage return that is not part of a CRLF pair. `canonicalize`
    /// normalizes it silently, which would corrupt the file on save; code
    /// treats it as read-only instead.
    static func hasLoneCarriageReturn(_ data: Data) -> Bool {
        var previousWasCR = false
        for byte in data {
            if previousWasCR, byte != 0x0A {
                return true
            }
            previousWasCR = byte == 0x0D
        }
        return previousWasCR
    }
}
