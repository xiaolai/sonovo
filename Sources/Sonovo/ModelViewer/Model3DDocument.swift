import Foundation
import Observation
import SonovoCore

enum Model3DLoadState: Equatable, Sendable {
    case needsConversion
    case converting
    case conversionFailed(String)
    case loading(Double?)
    case ready
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var isReady: Bool { self == .ready }

    var isConverting: Bool { self == .converting }

    var errorMessage: String? {
        switch self {
        case .conversionFailed(let message), .failed(let message):
            message
        case .needsConversion, .converting, .loading, .ready:
            nil
        }
    }
}

/// One read-only model file. There is no save path and no dirty state: the
/// source stays untouched, and a `.blend` conversion lives only in a
/// temporary directory.
@MainActor
@Observable
final class Model3DDocument: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let format: Model3DFormat
    private(set) var fileSize: Int64

    private(set) var sourceModifiedAt: Date?
    private(set) var state: Model3DLoadState
    private(set) var stats: Model3DStats?
    private(set) var animations: [Model3DAnimation] = []
    private(set) var sceneNames: [String] = []
    private(set) var renderableURL: URL?
    private(set) var temporaryDirectory: URL?
    private(set) var convertedFrom: URL?
    private(set) var blenderVersion: String?
    private(set) var conversionLog = ""
    private(set) var warning: String?
    private(set) var loadGeneration: UInt64 = 0
    private(set) var fitRequest: UInt64 = 0
    private var conversionSourceDate: Date?

    var hasExternalChange = false
    var upAxis: Model3DUpAxis
    var isAnimationPlaying = true
    var selectedClip = 0
    private(set) var selectedScene = 0

    init(url: URL, format: Model3DFormat) {
        let canonical = MarkdownSecurity.canonical(url)
        sourceURL = canonical
        self.format = format
        fileSize = Self.fileSize(of: canonical)
        sourceModifiedAt = Self.modifiedDate(of: canonical)
        upAxis = format.defaultUpAxis
        state = format.isConvertible ? .needsConversion : .loading(nil)
        renderableURL = format.isConvertible ? nil : canonical
    }

    var displayName: String { sourceURL.lastPathComponent }

    var isConverted: Bool { convertedFrom != nil }

    var materialURLs: [URL] {
        guard format == .obj else { return [] }
        let declared = declaredMaterialURLs()
        if !declared.isEmpty {
            return declared
        }
        let candidate = sourceURL.deletingPathExtension()
            .appendingPathExtension("mtl")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return []
        }
        return [candidate]
    }

    /// The material libraries' paths relative to the model's directory. A
    /// `mtllib` may name a subdirectory, so the viewer must request the whole
    /// relative path instead of dropping to the file's last component.
    var materialPaths: [String] {
        let directory = MarkdownSecurity.canonical(
            sourceURL.deletingLastPathComponent()
        )
        let rootPath = directory.path.hasSuffix("/")
            ? directory.path
            : directory.path + "/"
        return materialURLs.compactMap { url in
            guard url.path.hasPrefix(rootPath) else { return nil }
            return String(url.path.dropFirst(rootPath.count))
        }
    }

    /// OBJ files name their material libraries in `mtllib` lines. Honour every
    /// declaration before falling back to the same-basename convention, and
    /// never point outside the model's own directory.
    ///
    /// The whole file is scanned in chunks rather than a fixed prefix, so a
    /// declaration cannot be lost no matter how much geometry precedes it.
    /// Only one chunk and one partial line are held at a time.
    private func declaredMaterialURLs() -> [URL] {
        guard let handle = try? FileHandle(forReadingFrom: sourceURL) else {
            return []
        }
        defer { try? handle.close() }
        let directory = MarkdownSecurity.canonical(
            sourceURL.deletingLastPathComponent()
        )
        let rootPath = directory.path.hasSuffix("/")
            ? directory.path
            : directory.path + "/"
        var resolved: [URL] = []
        var seen: Set<String> = []
        var carry = Data()
        while true {
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: 1_048_576),
                      !read.isEmpty else {
                    break
                }
                chunk = read
            } catch {
                return resolved
            }
            carry.append(chunk)
            var lineStart = carry.startIndex
            while let newline = carry[lineStart...].firstIndex(of: 0x0A) {
                if let candidate = materialURL(
                    in: carry[lineStart..<newline],
                    directory: directory,
                    rootPath: rootPath
                ), !seen.contains(candidate.path) {
                    seen.insert(candidate.path)
                    resolved.append(candidate)
                }
                lineStart = carry.index(after: newline)
            }
            carry = Data(carry[lineStart...])
            if carry.count > 1_048_576 {
                // No newline in a megabyte cannot be a meaningful declaration.
                carry.removeAll(keepingCapacity: true)
            }
        }
        if let candidate = materialURL(
            in: carry,
            directory: directory,
            rootPath: rootPath
        ), !seen.contains(candidate.path) {
            resolved.append(candidate)
        }
        return resolved
    }

    /// Reads one `mtllib` line. The raw bytes are filtered first so a large
    /// OBJ's vertex and face lines are never decoded as strings.
    private func materialURL(
        in line: Data,
        directory: URL,
        rootPath: String
    ) -> URL? {
        var index = line.startIndex
        while index < line.endIndex,
              line[index] == 0x20 || line[index] == 0x09 || line[index] == 0x0D {
            index = line.index(after: index)
        }
        let directive = Array("mtllib".utf8)
        guard line.distance(from: index, to: line.endIndex) >= directive.count
        else { return nil }
        for expected in directive {
            var byte = line[index]
            if byte >= 0x41, byte <= 0x5A {
                byte += 0x20
            }
            guard byte == expected else { return nil }
            index = line.index(after: index)
        }
        guard index < line.endIndex,
              line[index] == 0x20 || line[index] == 0x09 else {
            return nil
        }
        // The rest of the line is the library name. OBJLoader reads the whole
        // remainder too, which keeps filenames containing spaces usable;
        // tabs are accepted as the separator.
        let name = String(decoding: line[index...], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let candidate = MarkdownSecurity.canonical(
            directory.appendingPathComponent(name)
        )
        guard candidate.path.hasPrefix(rootPath),
              FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }

    var fileSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    // MARK: - Loading

    func beginLoading() {
        refreshSourceMetadata()
        state = .loading(nil)
        stats = nil
        animations = []
        // Keep the scene names and selection so a reload restores the scene
        // the user was viewing. The loaded event replaces them.
        warning = nil
        hasExternalChange = false
        selectedClip = 0
        isAnimationPlaying = true
        newLoadIdentity()
    }

    func reload() {
        if format.isConvertible {
            discardConversion()
            state = .needsConversion
            newLoadIdentity()
        } else {
            beginLoading()
        }
    }

    func updateProgress(_ fraction: Double?) {
        guard state.isLoading else { return }
        let clamped = fraction.map { min(max($0, 0), 1) }
        state = .loading(clamped)
    }

    func apply(
        stats: Model3DStats,
        animations: [Model3DAnimation],
        scenes: [String],
        scene: Int
    ) {
        self.stats = stats
        self.animations = animations
        sceneNames = scenes
        selectedScene = scenes.isEmpty
            ? 0
            : min(max(scene, 0), scenes.count - 1)
        if animations.isEmpty {
            selectedClip = 0
            isAnimationPlaying = false
        } else {
            selectedClip = min(max(selectedClip, 0), animations.count - 1)
        }
        state = .ready
    }

    func applyScene(
        index: Int,
        stats: Model3DStats,
        animations: [Model3DAnimation]
    ) {
        guard !sceneNames.isEmpty else { return }
        selectedScene = min(max(index, 0), sceneNames.count - 1)
        self.stats = stats
        self.animations = animations
        if animations.isEmpty {
            selectedClip = 0
            isAnimationPlaying = false
        } else {
            selectedClip = min(max(selectedClip, 0), animations.count - 1)
        }
    }

    func selectScene(_ index: Int) {
        guard !sceneNames.isEmpty else { return }
        selectedScene = min(max(index, 0), sceneNames.count - 1)
    }

    func fail(_ message: String) {
        resetLoadedContent()
        isAnimationPlaying = false
        state = .failed(message)
    }

    func setWarning(_ message: String?) {
        warning = message
    }

    func dismissWarning() {
        warning = nil
    }

    func requestFit() {
        fitRequest &+= 1
    }

    func setUpAxis(_ axis: Model3DUpAxis) {
        upAxis = axis
    }

    func selectClip(_ index: Int) {
        guard !animations.isEmpty else {
            selectedClip = 0
            return
        }
        selectedClip = min(max(index, 0), animations.count - 1)
    }

    func markExternalChange() {
        hasExternalChange = true
    }

    func dismissExternalChange() {
        hasExternalChange = false
    }

    func refreshSourceMetadata() {
        sourceModifiedAt = Self.modifiedDate(of: sourceURL)
        fileSize = Self.fileSize(of: sourceURL)
    }

    // MARK: - Conversion

    func beginConversion() {
        guard format.canConvertWithBlender else { return }
        // A re-conversion replaces the previous derived output. Remove it now
        // so a failure cannot leave two temporary directories behind.
        cleanUpTemporaryOutput()
        convertedFrom = nil
        blenderVersion = nil
        refreshSourceMetadata()
        state = .converting
        conversionLog = ""
        warning = nil
        hasExternalChange = false
        conversionSourceDate = sourceModifiedAt
        resetLoadedContent()
    }

    func finishConversion(
        outputURL: URL,
        temporaryDirectory: URL,
        blenderVersion: String?,
        log: String,
        warnings: [String]
    ) {
        let sourceChanged = Self.modifiedDate(of: sourceURL)
            != conversionSourceDate
        self.convertedFrom = sourceURL
        self.renderableURL = outputURL
        self.temporaryDirectory = temporaryDirectory
        self.blenderVersion = blenderVersion
        conversionLog = log
        state = .loading(nil)
        resetLoadedContent()
        selectedClip = 0
        isAnimationPlaying = true
        refreshSourceMetadata()
        hasExternalChange = sourceChanged
        warning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        newLoadIdentity()
    }

    func failConversion(_ message: String, log: String) {
        state = .conversionFailed(message)
        conversionLog = log
        renderableURL = nil
        convertedFrom = nil
        blenderVersion = nil
        resetLoadedContent()
        isAnimationPlaying = false
    }

    func cancelConversion() {
        state = .needsConversion
        renderableURL = nil
        convertedFrom = nil
        blenderVersion = nil
        resetLoadedContent()
        conversionLog = ""
    }

    func discardConversion() {
        cleanUpTemporaryOutput()
        convertedFrom = nil
        blenderVersion = nil
        renderableURL = format.isConvertible ? nil : sourceURL
        resetLoadedContent()
        conversionLog = ""
    }

    private func resetLoadedContent() {
        stats = nil
        animations = []
        sceneNames = []
        selectedScene = 0
    }

    func cleanUpTemporaryOutput() {
        guard let temporaryDirectory else { return }
        let root = Self.temporaryRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let directory = temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard directory.path.hasPrefix(rootPath) else { return }
        try? FileManager.default.removeItem(at: directory)
        self.temporaryDirectory = nil
        if let renderableURL,
           renderableURL.resolvingSymlinksInPath().path
            .hasPrefix(directory.path + "/") {
            self.renderableURL = nil
        }
    }

    static var temporaryRoot: URL {
        Model3DTemporaryFiles.root
    }

    private func newLoadIdentity() {
        loadGeneration &+= 1
    }

    static func fileSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    static func modifiedDate(of url: URL) -> Date? {
        let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        )
        return values?.contentModificationDate
    }
}
