import CryptoKit
import Foundation

/// How a project's terminals are launched. The default is disabled so tests
/// and offline projects never spawn a tmux process; the app injects the live
/// environment and the setting that enables it.
struct TerminalEnvironment: Sendable {
    let tmux: (any TmuxControlling)?
    let isEnabled: @Sendable () -> Bool

    static let disabled = TerminalEnvironment(
        tmux: nil,
        isEnabled: { false }
    )

    static func live(
        isEnabled: @escaping @Sendable () -> Bool
    ) -> TerminalEnvironment {
        TerminalEnvironment(tmux: LiveTmux.shared, isEnabled: isEnabled)
    }
}

/// The slice of tmux the app needs. `LiveTmux` runs the binary; tests use a
/// fake so no process is ever spawned.
protocol TmuxControlling: AnyObject, Sendable {
    var isAvailable: Bool { get }
    /// nil means tmux could not answer; callers must not assume absence.
    func sessionNames(prefix: String) -> [String]?
    func sessionExists(name: String) -> Bool?
    func launchInput(name: String, directory: String) -> String
    func kill(name: String) -> Bool
    func runningSessions(
        candidates: Set<String>,
        shellNames: Set<String>
    ) -> Set<String>?
}

enum TmuxNaming {
    /// A short project label. Punctuation and spaces collapse to a hyphen;
    /// letters and digits, including non-Latin scripts, are kept. The path
    /// hash is what actually makes the name unique.
    static func slug(_ projectName: String) -> String {
        var result = ""
        var lastWasHyphen = false
        for scalar in projectName.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
        }
        let trimmed = result.trimmingCharacters(
            in: CharacterSet(charactersIn: "-")
        )
        let bounded = String(trimmed.prefix(24))
        return bounded.isEmpty ? "project" : bounded
    }

    /// Stable project discriminator: the same folder always yields the same
    /// eight hex characters, and two same-named folders do not collide.
    static func hash8(_ canonicalPath: String) -> String {
        let digest = SHA256.hash(data: Data(canonicalPath.utf8))
        return digest.prefix(4).map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func prefix(projectKey: String, projectName: String) -> String {
        if projectKey == "sample" { return "sonovo-sample-" }
        return "sonovo-\(slug(projectName))-\(hash8(projectKey))-"
    }

    static func sessionName(prefix: String, index: Int) -> String {
        "\(prefix)\(index)"
    }

    /// Only canonical positive indexes are accepted. Leading zeros and
    /// absurd values are ignored rather than aliasing another tab or
    /// overflowing `highestTmuxIndex + 1`.
    static func index(of name: String, prefix: String) -> Int? {
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = name.dropFirst(prefix.count)
        guard !suffix.isEmpty,
              suffix.first != "0",
              suffix.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(suffix),
              value > 0,
              value <= 999_999 else {
            return nil
        }
        return value
    }

    /// POSIX single-quote escaping. The input is already sanitized for
    /// session names, but directories are arbitrary user paths.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The shell line typed into a fresh terminal. Kept pure so the quoting is
/// testable without starting a process.
///
/// The line attaches an existing session or creates one, and sets tmux's two
/// unattached-session policies inside the same client before it attaches.
/// Exact `=name` targets stop tmux turning a missing `-1` into an existing
/// `-10`.
enum TmuxCommands {
    static func open(
        executable: String,
        name: String,
        directory: String,
        shell: String = "",
        loginShell: Bool = false
    ) -> String {
        let tool = commandToken(executable)
        let target = TmuxNaming.shellQuote("=" + name)
        let quotedName = TmuxNaming.shellQuote(name)
        // `set-option` resolves `-t` itself and rejects the `=` exact-match
        // prefix (tmux 3.8 answers "no such session"), so it targets the
        // plain name; the exact name exists by then, and has-session/attach
        // keep `=` for the missing-`-1` case.
        let sessionTarget = quotedName
        let quotedDirectory = TmuxNaming.shellQuote(directory)
        // The configured shell runs inside the new session. An empty shell
        // leaves tmux's own default in place.
        let command = shell.isEmpty
            ? ""
            : " \(TmuxNaming.shellQuote(shell))\(loginShell ? " -l" : "")"
        // One tmux client per branch: the server option, the session
        // option, creation, and attach all happen before that client can
        // disconnect. This closes the window where a hostile
        // `destroy-unattached` or `exit-unattached` could remove the
        // session between separate commands.
        let attach = "exec \(tool) set-option -s exit-unattached off "
            + "\\; set-option -t \(sessionTarget) destroy-unattached off "
            + "\\; attach -t \(target)"
        let setup = "\(tool) set-option -s exit-unattached off "
            + "\\; new-session -d -s \(quotedName) "
            + "-c \(quotedDirectory)\(command) "
            + "\\; set-option -t \(sessionTarget) destroy-unattached off"
        // A launcher that loses the has-session race still attaches: setup
        // is allowed to fail (duplicate session) and the second client
        // attaches to the exact name. The winner's own setup protected the
        // session before it detached.
        let create = "\(setup) 2>/dev/null; \(attach)"
        // `has-session` may start a server with no sessions; that server
        // exits on its own. The branch that follows starts a fresh server
        // and sets both persistence options in the same client.
        return "if \(tool) has-session -t \(target) 2>/dev/null; "
            + "then \(attach); else \(create); fi\n"
    }

    /// The command shown in the tab's “Copy tmux Attach Command” action.
    /// Exact `=name` so a stale `-1` never attaches `-10`.
    static func attachShellCommand(name: String) -> String {
        "tmux attach -t " + TmuxNaming.shellQuote("=" + name)
    }

    private static func commandToken(_ executable: String) -> String {
        TmuxNaming.shellQuote(executable)
    }
}

/// Parses the one bulk `list-panes` call. A session is busy when any pane's
/// foreground command is not a shell.
enum TmuxProbe {
    static func runningSessions(
        from output: String,
        candidates: Set<String>,
        shellNames: Set<String>,
        busyShellPIDs: Set<Int32> = []
    ) -> Set<String> {
        var running: Set<String> = []
        for line in output.split(separator: "\n") {
            let fields = line.split(
                separator: "\t",
                maxSplits: 2
            ).map(String.init)
            guard fields.count == 3,
                  candidates.contains(fields[0]) else {
                continue
            }
            let command = (fields[2] as NSString).lastPathComponent
            if !shellNames.contains(command) {
                running.insert(fields[0])
            } else if let pid = Int32(fields[1]),
                      busyShellPIDs.contains(pid) {
                // A shell running a script is still a busy pane.
                running.insert(fields[0])
            }
        }
        return running
    }
}

/// A tmux server is per user and local to this machine; only SSH is a remote
/// path. No listener is opened here.
final class LiveTmux: TmuxControlling, @unchecked Sendable {
    static let shared = LiveTmux()

    let isAvailable: Bool
    private let executable: String?
    private static let extraPaths =
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    private static let deadline: TimeInterval = 2

    init() {
        executable = Self.resolveExecutable()
        isAvailable = executable != nil
    }

    /// The resolved binary path, for diagnostics. nil when tmux is absent.
    var executablePath: String? { executable }

    /// The binary's version line (`tmux 3.8`), or nil when it cannot answer.
    /// Bounded by the same deadline as every other call.
    func version() -> String? {
        guard let result = run(["-V"]), result.status == 0 else {
            return nil
        }
        let value = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func sessionNames(prefix: String) -> [String]? {
        guard isAvailable,
              let result = run([
                  "list-sessions",
                  "-F",
                  "#{session_name}"
              ]) else {
            return nil
        }
        if result.status != 0 {
            // "no server running" is a confirmed empty list. A timeout or a
            // real server error is unknown, and callers must not treat it as
            // proof that a name is free.
            return result.output.lowercased().contains("no server running")
                ? []
                : nil
        }
        return result.output
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix(prefix) }
    }

    func sessionExists(name: String) -> Bool? {
        guard isAvailable,
              let result = run([
                  "list-sessions",
                  "-F",
                  "#{session_name}"
              ]) else {
            return nil
        }
        if result.status == 0 {
            return result.output
                .split(separator: "\n")
                .map(String.init)
                .contains(name)
        }
        // Only "no server running" is a confirmed absence. Any other
        // failure is unknown and must not cause a tab to be discarded.
        if result.output.localizedCaseInsensitiveContains(
            "no server running"
        ) {
            return false
        }
        return nil
    }

    func launchInput(name: String, directory: String) -> String {
        guard let executable else { return "" }
        return TmuxCommands.open(
            executable: executable,
            name: name,
            directory: directory,
            shell: Preferences.effectiveShell,
            loginShell: Preferences.loginShell
        )
    }

    func kill(name: String) -> Bool {
        guard isAvailable else { return false }
        return run([
            "kill-session",
            "-t",
            "=\(name)"
        ])?.status == 0
    }

    func runningSessions(
        candidates: Set<String>,
        shellNames: Set<String>
    ) -> Set<String>? {
        guard isAvailable else { return nil }
        guard !candidates.isEmpty else { return [] }
        guard let result = run([
            "list-panes",
            "-a",
            "-F",
            "#{session_name}\t#{pane_pid}\t#{pane_current_command}"
        ]), result.status == 0 else {
            return nil
        }
        guard let busyShellPIDs = Self.parentPIDs() else {
            // Without the process tree a shell pane cannot be classified.
            // Unknown must not become "idle".
            return nil
        }
        return TmuxProbe.runningSessions(
            from: result.output,
            candidates: candidates,
            shellNames: shellNames,
            busyShellPIDs: busyShellPIDs
        )
    }

    /// Parents of every running process, from one `ps` call. A shell pane in
    /// this set has a child and is executing work, not sitting at a prompt.
    /// nil means the process table could not be read; callers must treat the
    /// result as unknown rather than idle.
    private static func parentPIDs() -> Set<Int32>? {
        guard let result = runProcess(
            "/bin/ps",
            ["-axo", "pid=,ppid="]
        ), result.status == 0 else {
            return nil
        }
        var parents: Set<Int32> = []
        for line in result.output.split(separator: "\n") {
            let fields = line.split(whereSeparator: {
                $0 == " " || $0 == "\t"
            }).compactMap { Int32($0) }
            if fields.count == 2 {
                parents.insert(fields[1])
            }
        }
        return parents
    }

    private static func resolveExecutable() -> String? {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
            "/opt/local/bin/tmux"
        ]
        for path in candidates
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Do not fall back to PATH: the controller and the terminal shell
        // can resolve different binaries, which breaks launch/kill symmetry.
        return nil
    }

    private func run(_ arguments: [String]) -> ProcessResult? {
        guard let executable else { return nil }
        return Self.runProcess(executable, arguments)
    }

    private struct ProcessResult {
        let status: Int32
        let output: String
    }

    /// Bounded so a wedged tmux cannot freeze the main actor forever.
    /// Output goes to a temporary file, not a pipe: a descendant holding a
    /// pipe open can block EOF forever, and a full pipe can block the child.
    private static func runProcess(
        _ executable: String,
        _ arguments: [String]
    ) -> ProcessResult? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sonovo-tmux-\(UUID().uuidString).out"
            )
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil
        ), let handle = try? FileHandle(forWritingTo: outputURL) else {
            return nil
        }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = environment["PATH"].map {
            "\(extraPaths):\($0)"
        } ?? extraPaths
        process.environment = environment
        process.standardOutput = handle
        // Combined with stdout so an error message can distinguish "no
        // server running" from a real failure.
        process.standardError = handle
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadlineDate = Date().addingTimeInterval(deadline)
        while process.isRunning, Date() < deadlineDate {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            // Do not wait after SIGTERM; a process that ignores it must not
            // extend the caller's bound.
            process.terminate()
            return nil
        }
        try? handle.close()
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        return ProcessResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }
}
