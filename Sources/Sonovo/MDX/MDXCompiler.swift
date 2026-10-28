import Foundation
import SonovoMDXKit

enum MDXCompilerError: Error, LocalizedError, Equatable {
    case helperUnavailable
    case compilerUnavailable
    case launchFailed(String)
    case timedOut
    case failed(exitCode: Int32, message: String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            "The MDX compiler helper is missing from this build."
        case .compilerUnavailable:
            "The bundled MDX compiler is missing from this build."
        case .launchFailed(let detail):
            "The MDX compiler could not start: \(detail)"
        case .timedOut:
            "The MDX compiler took too long and was stopped."
        case .failed(let exitCode, let message):
            "The MDX compiler failed (exit \(exitCode)): \(message)"
        case .invalidResponse(let detail):
            "The MDX compiler returned an unreadable response: \(detail)"
        }
    }
}

/// Anchors `Bundle(for:)` to this module: under XCTest it resolves the test
/// bundle, and in the app it resolves the app bundle.
private final class MDXModuleAnchor {}

/// Runs the vendored MDX compiler in a separate, sandboxed process.
///
/// The helper receives every source in one request file; it never opens the
/// project. `/usr/bin/sandbox-exec` denies network and file writes, so even a
/// JavaScriptCore escape could not reach the network or modify a file. The
/// app never evaluates MDX in its own process.
struct MDXHelperCompiler: Sendable {
    /// The sandbox profile is constant: no project path is interpolated, so
    /// a crafted path cannot change the policy.
    static let sandboxProfile =
        "(version 1)(allow default)(deny network*)(deny file-write*)"

    static let defaultTimeout: Duration = .seconds(10)

    let helperURL: URL
    let compilerScriptURL: URL
    let timeout: Duration

    init(
        helperURL: URL,
        compilerScriptURL: URL,
        timeout: Duration = MDXHelperCompiler.defaultTimeout
    ) {
        self.helperURL = helperURL
        self.compilerScriptURL = compilerScriptURL
        self.timeout = timeout
    }

    /// The compiler from the app's resource bundle and the helper from the
    /// bundle, the build tree, or `SONOVO_MDX_HELPER`.
    static func appDefault(bundle: Bundle = .main) -> MDXHelperCompiler? {
        guard let compiler = Bundle.module.url(
            forResource: "mdx-compiler-3.1.1",
            withExtension: "js"
        ) else {
            return nil
        }
        guard let helper = locateHelper(bundle: bundle) else {
            return nil
        }
        return MDXHelperCompiler(
            helperURL: helper,
            compilerScriptURL: compiler
        )
    }

    static func locateHelper(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates: [URL] = []
        if let override = environment["SONOVO_MDX_HELPER"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(
            bundle.bundleURL
                .appendingPathComponent("Contents/Helpers/SonovoMDXHelper")
        )
        if let executable = bundle.executableURL {
            candidates.append(
                executable.deletingLastPathComponent()
                    .appendingPathComponent("SonovoMDXHelper")
            )
        }
        // A `swift test` run and a direct `.build/debug/Sonovo` run both keep
        // the helper next to the products, not inside an app bundle. This
        // fallback is for development; the shipped app uses Contents/Helpers.
        // The search walks the ancestors of the bundle that contains this
        // module's code — under XCTest, Bundle.main is the xctest tool and
        // shares no ancestor with the build tree — instead of deriving a
        // path from this file's location, which would embed the builder's
        // home directory in the shipped binary. A candidate is considered
        // only inside a build tree, so an executable that happens to share
        // the helper's name next to an installed app is never run.
        var ancestor = Bundle(for: MDXModuleAnchor.self).bundleURL
        for _ in 0..<8 {
            if ancestor.path.contains("/.build/") {
                candidates.append(
                    ancestor.appendingPathComponent("SonovoMDXHelper")
                )
            }
            ancestor.deleteLastPathComponent()
        }
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    func compile(
        _ request: MDXCompileRequest
    ) async throws -> MDXCompileResponse {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path)
        else {
            throw MDXCompilerError.helperUnavailable
        }
        guard FileManager.default.fileExists(
            atPath: compilerScriptURL.path
        ) else {
            throw MDXCompilerError.compilerUnavailable
        }
        let requestURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sonovo-mdx-\(UUID().uuidString).json"
            )
        do {
            let data = try JSONEncoder().encode(request)
            try data.write(to: requestURL, options: .atomic)
        } catch {
            throw MDXCompilerError.launchFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: requestURL) }

        let helper = helperURL
        let compiler = compilerScriptURL
        let timeout = timeout
        let holder = HelperProcess()
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let response = try Self.runHelper(
                                helperURL: helper,
                                compilerURL: compiler,
                                requestURL: requestURL,
                                timeout: timeout,
                                holder: holder
                            )
                            continuation.resume(returning: response)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                // Closing a document or disabling the preview must stop the
                // helper now, not wait out the remaining timeout.
                holder.cancel()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    // MARK: - Process

    /// Stops a child that cancellation raced with: SIGTERM, a short grace
    /// period, then SIGKILL, and always reap it so the process table does not
    /// keep a zombie. Called off the main actor.
    private static func terminateAndReap(_ process: Process) {
        let pid = process.processIdentifier
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline {
                usleep(50_000)
            }
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
        process.waitUntilExit()
    }

    private static func runHelper(
        helperURL: URL,
        compilerURL: URL,
        requestURL: URL,
        timeout: Duration,
        holder: HelperProcess
    ) throws -> MDXCompileResponse {
        guard !holder.isCancelled else { throw CancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = [
            "-p", sandboxProfile,
            helperURL.path,
            compilerURL.path,
            requestURL.path
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw MDXCompilerError.launchFailed(error.localizedDescription)
        }
        // A cancel that landed between the guard above and `run` still has
        // to stop the helper. SIGTERM alone is not enough: use the same
        // bounded escalation as the watchdog and reap the child.
        guard holder.attach(process) else {
            Self.terminateAndReap(process)
            throw CancellationError()
        }
        defer { holder.detach() }

        let timedOut = TimeoutFlag()
        let pid = process.processIdentifier
        let seconds = max(
            0.1,
            Double(timeout.components.seconds)
                + Double(timeout.components.attoseconds) / 1e18
        )
        let watchdog = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        watchdog.schedule(deadline: .now() + seconds)
        watchdog.setEventHandler {
            timedOut.mark()
            // `Process.isRunning` tracks this child; a raw `kill(pid, 0)`
            // could hit an unrelated process once the PID is reused.
            if process.isRunning {
                process.terminate()
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + 1
            ) {
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }
        watchdog.resume()

        // Drain both pipes concurrently. Reading stdout to EOF first
        // deadlocks once the helper writes more than a pipe buffer of
        // diagnostics: the child blocks in write(2) and never closes stdout.
        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let drainGroup = DispatchGroup()
        let drainQueue = DispatchQueue.global(qos: .userInitiated)
        drainGroup.enter()
        drainQueue.async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutBox.set(data)
            drainGroup.leave()
        }
        drainGroup.enter()
        drainQueue.async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrBox.set(data)
            drainGroup.leave()
        }
        process.waitUntilExit()
        if drainGroup.wait(timeout: .now() + 2) == .timedOut {
            // A descendant may hold the write end open after the helper
            // exits. Closing the read ends releases the drain threads; the
            // watchdog deadline already bounds the helper itself.
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            _ = drainGroup.wait(timeout: .now() + 1)
        }
        watchdog.cancel()
        let stdout = stdoutBox.value
        let stderr = stderrBox.value

        if timedOut.isMarked {
            throw MDXCompilerError.timedOut
        }
        let message = String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw MDXCompilerError.failed(
                exitCode: process.terminationStatus,
                message: message.isEmpty ? "no diagnostic" : message
            )
        }

        let envelope: HelperOutput
        do {
            envelope = try JSONDecoder().decode(HelperOutput.self, from: stdout)
        } catch {
            throw MDXCompilerError.invalidResponse(
                error.localizedDescription
            )
        }
        if envelope.ok {
            return MDXCompileResponse(
                ok: true,
                entry: envelope.entry,
                modules: envelope.modules ?? [],
                diagnostic: nil
            )
        }
        return .failure(
            MDXCompileDiagnostic(
                message: envelope.error ?? "MDX compilation failed.",
                line: envelope.line,
                column: envelope.column
            )
        )
    }

    private struct HelperOutput: Decodable {
        let ok: Bool
        let entry: String?
        let modules: [MDXCompiledModule]?
        let error: String?
        let line: Int?
        let column: Int?
    }
}

/// A byte buffer filled from a background drain.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// A flag shared between the watchdog and the caller's thread.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false

    func mark() {
        lock.lock()
        marked = true
        lock.unlock()
    }

    var isMarked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return marked
    }
}

/// The helper child for one compile, reachable from the task that cancels
/// it. The lock is held only for flag and reference swaps; it never wraps
/// the blocking wait.
private final class HelperProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Returns false when cancellation won the race with `run()`.
    func attach(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    func detach() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running, running.isRunning {
            running.terminate()
        }
    }
}
