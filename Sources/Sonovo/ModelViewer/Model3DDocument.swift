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
    /// Every asset the page requested for the current model: the primary
    /// file, `.bin`, MTL, textures. A project watcher uses this to reload the
    /// model when a sidecar changes, not only when the primary file does.
    private(set) var resourcePaths: Set<String> = []
    private(set) var resourceRevisions: [String: AssetRevision] = [:]
    /// The OBJ material libraries are scanned off the main actor. The web
    /// view waits until this is true so its first load already has them.
    private(set) var materialsReady = true
    private var cachedMaterialPaths: [String] = []
    private var materialRevision: AssetRevision?
    private var materialTask: Task<Void, Never>?
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

    /// The material libraries' paths relative to the model's directory. A
    /// `mtllib` may name a subdirectory, so the viewer must request the whole
    /// relative path instead of dropping to the file's last component.
    var materialPaths: [String] { cachedMaterialPaths }

    private func scheduleMaterialScan() {
        materialTask?.cancel()
        materialTask = nil
        guard format == .obj else {
            cachedMaterialPaths = []
            materialRevision = nil
            materialsReady = true
            return
        }
        let url = sourceURL
        let revision = Self.revision(of: url)
        if materialRevision == revision, materialCacheIsCurrent() {
            materialsReady = true
            return
        }
        materialsReady = false
        materialTask = Task { @MainActor [weak self] in
            let scan = Task.detached(priority: .userInitiated) {
                Self.scanMaterialPaths(sourceURL: url)
            }
            let paths = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            guard let self, !Task.isCancelled else { return }
            guard Self.revision(of: url) == revision else {
                // The OBJ changed while it was scanned. Scan the new
                // revision instead of leaving the viewer blocked forever.
                self.materialTask = nil
                self.scheduleMaterialScan()
                return
            }
            self.cachedMaterialPaths = paths
            self.materialRevision = revision
            self.materialsReady = true
            // The page must be created after the paths are known; if an old
            // page exists, give the view a new identity to install them.
            self.newLoadIdentity()
        }
    }

    /// A cached empty list is not proof that no material library exists: the
    /// MTL may have been created after the previous scan.
    private func materialCacheIsCurrent() -> Bool {
        let directory = sourceURL.deletingLastPathComponent()
        if !cachedMaterialPaths.isEmpty {
            return cachedMaterialPaths.allSatisfy {
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent($0).path
                )
            }
        }
        let sibling = sourceURL.deletingPathExtension()
            .appendingPathExtension("mtl")
        return !FileManager.default.fileExists(atPath: sibling.path)
    }

    nonisolated static func scanMaterialPaths(
        sourceURL: URL
    ) -> [String] {
        guard sourceURL.pathExtension.lowercased() == "obj" else {
            return []
        }
        var urls = declaredMaterialURLs(sourceURL: sourceURL)
        if urls.isEmpty {
            let candidate = sourceURL.deletingPathExtension()
                .appendingPathExtension("mtl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                urls = [candidate]
            }
        }
        let directory = MarkdownSecurity.canonical(
            sourceURL.deletingLastPathComponent()
        )
        let rootPath = directory.path.hasSuffix("/")
            ? directory.path
            : directory.path + "/"
        return urls.compactMap { url in
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
    nonisolated private static func declaredMaterialURLs(
        sourceURL: URL
    ) -> [URL] {
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
            if Task.isCancelled { return resolved }
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
                for candidate in Self.materialURLs(
                    in: carry[lineStart..<newline],
                    directory: directory,
                    rootPath: rootPath
                ) where !seen.contains(candidate.path) {
                    seen.insert(candidate.path)
                    resolved.append(candidate)
                }
                lineStart = carry.index(after: newline)
                if Task.isCancelled { return resolved }
            }
            carry = Data(carry[lineStart...])
            if carry.count > 1_048_576 {
                // No newline in a megabyte cannot be a meaningful declaration.
                carry.removeAll(keepingCapacity: true)
            }
        }
        for candidate in Self.materialURLs(
            in: carry,
            directory: directory,
            rootPath: rootPath
        ) where !seen.contains(candidate.path) {
            resolved.append(candidate)
        }
        return resolved
    }

    /// Reads one `mtllib` line. The raw bytes are filtered first so a large
    /// OBJ's vertex and face lines are never decoded as strings. A line may
    /// name several libraries; a name containing spaces is tried as a whole
    /// before the line is split into tokens.
    nonisolated private static func materialURLs(
        in line: Data,
        directory: URL,
        rootPath: String
    ) -> [URL] {
        var index = line.startIndex
        while index < line.endIndex,
              line[index] == 0x20 || line[index] == 0x09 || line[index] == 0x0D {
            index = line.index(after: index)
        }
        let directive = Array("mtllib".utf8)
        guard line.distance(from: index, to: line.endIndex) >= directive.count
        else { return [] }
        for expected in directive {
            var byte = line[index]
            if byte >= 0x41, byte <= 0x5A {
                byte += 0x20
            }
            guard byte == expected else { return [] }
            index = line.index(after: index)
        }
        guard index < line.endIndex,
              line[index] == 0x20 || line[index] == 0x09 else {
            return []
        }
        let text = String(decoding: line[index...], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        func resolve(_ name: String) -> URL? {
            let trimmed = name
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let candidate = MarkdownSecurity.canonical(
                directory.appendingPathComponent(trimmed)
            )
            // Existence is deliberately not checked: the cached path list
            // must include a declared library that does not exist yet, so
            // creating it later invalidates the material cache.
            guard candidate.path.hasPrefix(rootPath) else { return nil }
            return candidate
        }

        // Prefer the whole remainder only when it names a real file: an
        // unquoted filename may contain spaces. Otherwise parse tokens, so
        // `mtllib first.mtl second.mtl` yields both libraries and a missing
        // library is still cached for later invalidation.
        if let whole = resolve(text),
           FileManager.default.fileExists(atPath: whole.path) {
            return [whole]
        }
        var names: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
                continue
            }
            if character.isWhitespace, !quoted {
                if !current.isEmpty {
                    names.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            names.append(current)
        }
        return names.compactMap(resolve)
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
        scheduleMaterialScan()
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
        sceneNames = scenes
        selectedScene = scenes.isEmpty
            ? 0
            : min(max(scene, 0), scenes.count - 1)
        updateAnimationState(animations)
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
        updateAnimationState(animations)
    }

    private func updateAnimationState(_ animations: [Model3DAnimation]) {
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
        Model3DTemporaryFiles.protect(temporaryDirectory)
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
        Model3DTemporaryFiles.unprotect(directory)
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
        resourcePaths.removeAll()
        resourceRevisions.removeAll()
    }

    func recordResourceServed(_ url: URL) {
        let canonical = MarkdownSecurity.canonical(url)
        resourcePaths.insert(canonical.path)
        resourceRevisions[canonical.path] = Self.revision(of: canonical)
    }

    /// Identity of a served resource at the time it was requested. A project
    /// scan compares this with the file's current identity, so a changed or
    /// deleted `.bin`, MTL, or texture reloads the model too.
    static func revision(of url: URL) -> AssetRevision {
        let values = try? url.resourceValues(
            forKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
        )
        return AssetRevision(
            fileIdentifier: values?.fileResourceIdentifier.map {
                String(describing: $0)
            },
            size: Int64(values?.fileSize ?? 0),
            modified: values?.contentModificationDate
        )
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
