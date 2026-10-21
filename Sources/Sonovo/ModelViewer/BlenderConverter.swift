import AppKit
import Foundation

enum Model3DTemporaryFiles {
    static var root: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Sonovo", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }
}

struct BlenderInstallation: Equatable, Sendable {
    let executableURL: URL
}

struct BlendConversionResult: Sendable {
    let outputURL: URL
    let temporaryDirectory: URL
    let installation: BlenderInstallation
    let version: String?
    let log: String
    var warnings: [String] = []
}

enum BlenderConversionError: LocalizedError {
    case notInstalled
    case missingScript
    case launchFailed(String)
    case timedOut(seconds: Int)
    case failed(status: Int32, log: String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Blender was not found. Install Blender or set SONOVO_BLENDER_PATH."
        case .missingScript:
            "The bundled Blender export script is missing."
        case .launchFailed(let message):
            "Blender could not start: \(message)"
        case .timedOut(let seconds):
            "Blender did not finish within \(seconds) seconds."
        case .failed(let status, _):
            "Blender exited with status \(status)."
        case .invalidOutput(let message):
            "Blender produced an invalid GLB: \(message)"
        }
    }

    var log: String {
        if case .failed(_, let log) = self { return log }
        return ""
    }
}

@MainActor
protocol BlendConverting: AnyObject {
    func locateBlender() -> BlenderInstallation?
    func convert(source: URL) async throws -> BlendConversionResult
    func terminateAll()
}

/// Finds Blender without launching it. Version output is read only after a
/// real conversion, so opening a `.blend` never spawns a process.
struct BlenderLocator {
    let environment: [String: String]
    let fileManager: FileManager
    let applicationURL: () -> URL?
    /// Tests disable the fixed locations so "Blender is not installed" is
    /// provable on a machine that has one.
    let includeStandardLocations: Bool

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        applicationURL: @escaping () -> URL? = {
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "org.blenderfoundation.blender"
            )
        },
        includeStandardLocations: Bool = true
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.applicationURL = applicationURL
        self.includeStandardLocations = includeStandardLocations
    }

    func locate() -> BlenderInstallation? {
        var candidates: [URL] = []
        if let explicit = environment["SONOVO_BLENDER_PATH"],
           !explicit.isEmpty {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        if includeStandardLocations, let application = applicationURL() {
            candidates.append(
                application.appendingPathComponent("Contents/MacOS/Blender")
            )
        }

        if includeStandardLocations {
            let home = environment["HOME"] ?? NSHomeDirectory()
            candidates.append(contentsOf: [
                URL(fileURLWithPath: "/opt/homebrew/bin/blender"),
                URL(fileURLWithPath: "/usr/local/bin/blender"),
                URL(fileURLWithPath: "/Applications/Blender.app/Contents/MacOS/Blender"),
                URL(fileURLWithPath: home)
                    .appendingPathComponent("Applications/Blender.app/Contents/MacOS/Blender")
            ])
        }

        if let path = environment["PATH"] {
            for directory in path.split(separator: ":").map(String.init) {
                candidates.append(
                    URL(fileURLWithPath: directory)
                        .appendingPathComponent("blender")
                )
            }
        }

        for candidate in candidates {
            let standardized = candidate.standardizedFileURL
            guard fileManager.isExecutableFile(atPath: standardized.path) else {
                continue
            }
            return BlenderInstallation(executableURL: standardized)
        }
        return nil
    }
}

@MainActor
final class BlenderConverter: BlendConverting {
    private let locator: BlenderLocator
    private let fileManager: FileManager
    private let scriptURL: URL?
    private let timeoutSeconds: Double
    private var processes: [ObjectIdentifier: Process] = [:]

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        scriptURL: URL? = BlenderConverter.bundledScriptURL(),
        locator: BlenderLocator? = nil
    ) {
        self.fileManager = fileManager
        self.scriptURL = scriptURL
        self.locator = locator ?? BlenderLocator(
            environment: environment,
            fileManager: fileManager
        )
        if let raw = environment["SONOVO_BLENDER_TIMEOUT_SECONDS"],
           let value = Double(raw),
           value > 0 {
            timeoutSeconds = value
        } else {
            timeoutSeconds = 300
        }
    }

    func locateBlender() -> BlenderInstallation? {
        locator.locate()
    }

    func convert(source: URL) async throws -> BlendConversionResult {
        guard let installation = locateBlender() else {
            throw BlenderConversionError.notInstalled
        }
        guard let scriptURL,
              fileManager.isReadableFile(atPath: scriptURL.path) else {
            throw BlenderConversionError.missingScript
        }

        let directory = Model3DTemporaryFiles.root
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw BlenderConversionError.launchFailed(error.localizedDescription)
        }

        let outputURL = directory.appendingPathComponent("model.glb")
        let process = Process()
        process.executableURL = installation.executableURL
        process.arguments = [
            "--background",
            "--factory-startup",
            "--disable-autoexec",
            "--python-exit-code", "1",
            "--python", scriptURL.path
        ]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": directory.path,
            "TMPDIR": directory.path,
            "LANG": "en_US.UTF-8",
            "SONOVO_BLEND_INPUT": source.path,
            "SONOVO_BLEND_OUTPUT": outputURL.path
        ]
        process.currentDirectoryURL = directory

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        let log = ConversionLog()
        let ioQueue = DispatchQueue(label: "sonovo.blender-io")

        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            ioQueue.async {
                log.append(handle.availableData)
            }
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            ioQueue.async {
                log.append(handle.availableData)
            }
        }

        processes[ObjectIdentifier(process)] = process
        defer { processes.removeValue(forKey: ObjectIdentifier(process)) }

        let status: Int32
        do {
            status = try await run(
                process,
                ioQueue: ioQueue,
                log: log,
                outputPipe: standardOutput,
                errorPipe: standardError
            )
        } catch {
            cleanup(directory)
            throw error
        }

        if Task.isCancelled {
            cleanup(directory)
            throw CancellationError()
        }

        let logText = log.text
        guard status == 0 else {
            cleanup(directory)
            throw BlenderConversionError.failed(
                status: status,
                log: logText
            )
        }
        guard log.containsSentinel else {
            cleanup(directory)
            throw BlenderConversionError.failed(status: status, log: logText)
        }

        do {
            try validateGLB(at: outputURL)
        } catch {
            cleanup(directory)
            throw error
        }

        return BlendConversionResult(
            outputURL: outputURL,
            temporaryDirectory: directory,
            installation: installation,
            version: log.version,
            log: logText,
            warnings: Self.warnings(from: logText)
        )
    }

    /// The export script reports fidelity choices as marker lines. They are
    /// surfaced once, after conversion, instead of being buried in the log.
    static func warnings(from log: String) -> [String] {
        var result: [String] = []
        for line in log.split(separator: "\n") {
            if line == "SONOVO_SHAPE_KEYS=1" {
                result.append(
                    "Shape keys were preserved; modifiers were not baked into the mesh."
                )
            } else if line.hasPrefix("SONOVO_PROCEDURAL_MATERIALS="),
                      let count = Int(line.dropFirst("SONOVO_PROCEDURAL_MATERIALS=".count)),
                      count > 0 {
                result.append(
                    "\(count) material\(count == 1 ? "" : "s") use procedural nodes; their appearance may differ."
                )
            } else if line.hasPrefix("SONOVO_SCENES="),
                      let count = Int(line.dropFirst("SONOVO_SCENES=".count)),
                      count > 1 {
                result.append(
                    "This file contains \(count) scenes; choose one in the header."
                )
            }
        }
        return Array(Set(result)).sorted()
    }

    func terminateAll() {
        for process in processes.values where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        processes.removeAll()
    }

    // MARK: - Process lifecycle

    private func run(
        _ process: Process,
        ioQueue: DispatchQueue,
        log: ConversionLog,
        outputPipe: Pipe,
        errorPipe: Pipe
    ) async throws -> Int32 {
        let gateway = ContinuationGateway()
        let timedOut = TimeoutFlag()
        let timeout = timeoutSeconds
        let box = ProcessBox(process)

        let timer = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            timedOut.set()
            self.terminate(box)
        }
        defer { timer.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    box.markFinished()
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    ioQueue.sync {
                        log.append(
                            outputPipe.fileHandleForReading.readDataToEndOfFile()
                        )
                        log.append(
                            errorPipe.fileHandleForReading.readDataToEndOfFile()
                        )
                    }
                    guard gateway.claim() else { return }
                    if timedOut.value {
                        continuation.resume(
                            throwing: BlenderConversionError.timedOut(
                                seconds: Int(timeout)
                            )
                        )
                    } else {
                        continuation.resume(returning: finished.terminationStatus)
                    }
                }
                do {
                    try process.run()
                } catch {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    process.terminationHandler = nil
                    guard gateway.claim() else { return }
                    continuation.resume(
                        throwing: BlenderConversionError.launchFailed(
                            error.localizedDescription
                        )
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.terminate(box)
            }
        }
    }

    private func terminate(_ box: ProcessBox) {
        let process = box.process
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            // A PID alone can hit a reused process. The finished flag and the
            // signal share one lock, so the termination handler marking the
            // process finished and this escalation cannot interleave: once
            // the handler has run, no signal is sent.
            box.killIfUnfinished()
        }
    }

    private func cleanup(_ directory: URL) {
        try? fileManager.removeItem(at: directory)
    }

    private func validateGLB(at url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values?.fileSize ?? 0)
        guard size >= 12 else {
            throw BlenderConversionError.invalidOutput(
                "the file is smaller than a GLB header"
            )
        }
        guard let handle = try? FileHandle(forReadingFrom: url),
              let header = try? handle.read(upToCount: 12),
              header.count == 12 else {
            throw BlenderConversionError.invalidOutput(
                "the GLB header could not be read"
            )
        }
        try? handle.close()

        guard header.prefix(4) == Data("glTF".utf8) else {
            throw BlenderConversionError.invalidOutput("the magic is not glTF")
        }
        let version = header.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        }
        guard version == 2 else {
            throw BlenderConversionError.invalidOutput(
                "GLB version \(version) is not supported"
            )
        }
        let declared = header.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
        }
        guard Int64(declared) == size else {
            throw BlenderConversionError.invalidOutput(
                "the header length does not match the file size"
            )
        }
    }

    private static func bundledScriptURL() -> URL? {
        ModelViewerResources.conversionScript
    }
}

/// Cancellation callbacks are not main-actor isolated; passing the Process
/// through a checked wrapper keeps the kill path off the generic executor.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    private let lock = NSLock()
    private var finished = false

    init(_ process: Process) {
        self.process = process
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    /// Sends SIGKILL only while the termination handler has not marked this
    /// process finished. The check and the signal hold the same lock the
    /// termination handler takes, and `isRunning` is the most current
    /// lifecycle state Process exposes, so every exit Foundation can observe
    /// is seen before the signal. Darwin has no pidfd, so the kernel-level
    /// race inside `kill` itself cannot be closed from user space.
    func killIfUnfinished() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}

private final class ContinuationGateway: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false

    func set() {
        lock.lock()
        flagged = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flagged
    }
}

/// Collects Blender's output without blocking the pipe. The tail is what the
/// failure UI shows; the sentinel is tracked separately so a long log cannot
/// push the success marker out of the retained window.
private final class ConversionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = ""
    private var probe = ""
    private var sawSentinel = false

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        lock.lock()
        defer { lock.unlock() }
        let combined = probe + text
        if combined.contains("SONOVO_EXPORT_OK") {
            sawSentinel = true
        }
        probe = String(combined.suffix(32))
        tail = String((tail + text).suffix(8192))
    }

    var containsSentinel: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawSentinel
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return tail
    }

    var version: String? {
        // The bundled script prints the version with the fidelity markers
        // after export, so it survives the 8 KiB tail. The banner form is a
        // fallback for logs produced without the marker.
        let marker = /SONOVO_BLENDER_VERSION=([0-9]+\.[0-9]+\.[0-9]+)/
        if let match = text.firstMatch(of: marker) {
            return String(match.1)
        }
        let pattern = /Blender ([0-9]+\.[0-9]+\.[0-9]+)/
        guard let match = text.firstMatch(of: pattern) else { return nil }
        return String(match.1)
    }
}
