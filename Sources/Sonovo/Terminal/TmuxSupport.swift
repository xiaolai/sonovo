import CryptoKit
import Foundation

/// How a project's terminals are launched. The default is disabled so tests
/// and offline projects never spawn a tmux process; the app injects the live
/// environment and the setting that enables it.
struct TerminalEnvironment: Sendable {
    let tmux: (any TmuxControlling)?
    let isEnabled: @Sendable () -> Bool
    /// Every destructive tmux path goes through one coordinator. Tests and
    /// disabled projects leave it nil and keep the store-local path.
    let coordinator: (@Sendable @MainActor () -> TmuxActionCoordinator?)?

    init(
        tmux: (any TmuxControlling)?,
        isEnabled: @escaping @Sendable () -> Bool,
        coordinator: (@Sendable @MainActor () -> TmuxActionCoordinator?)? = nil
    ) {
        self.tmux = tmux
        self.isEnabled = isEnabled
        self.coordinator = coordinator
    }

    static let disabled = TerminalEnvironment(
        tmux: nil,
        isEnabled: { false },
        coordinator: nil
    )

    static func live(
        isEnabled: @escaping @Sendable () -> Bool,
        coordinator: (@Sendable @MainActor () -> TmuxActionCoordinator?)? = nil
    ) -> TerminalEnvironment {
        TerminalEnvironment(
            tmux: LiveTmux.shared,
            isEnabled: isEnabled,
            coordinator: coordinator
        )
    }
}

/// Ownership metadata written into a session when Sonovo creates it. A name
/// is a discovery hint; this metadata and the local registry are the proof.
struct TmuxLaunchOwnership: Sendable, Equatable {
    let projectPath: String
    let appVersion: String
}

/// The slice of tmux the app needs. `LiveTmux` runs the binary; tests use a
/// fake so no process is ever spawned.
protocol TmuxControlling: AnyObject, Sendable {
    var isAvailable: Bool { get }
    /// nil means tmux could not answer; callers must not assume absence.
    func sessionNames(prefix: String) -> [String]?
    func sessionExists(name: String) -> Bool?
    func launchInput(name: String, directory: String) -> String
    func launchInput(
        name: String,
        directory: String,
        ownership: TmuxLaunchOwnership?
    ) -> String
    func attachOnlyInput(name: String) -> String
    /// The identity of a named session at this moment. nil is unknown.
    func sessionIdentity(named name: String) -> TmuxSessionIdentity?
    func kill(identity: TmuxSessionIdentity, name: String) -> Bool
    func kill(name: String) -> Bool
    func runningSessions(
        candidates: Set<String>,
        shellNames: Set<String>
    ) -> Set<String>?
}

extension TmuxHygieneServicing {
    func guardedKill(
        _ request: TmuxGuardedKill,
        isCancelled: @Sendable () -> Bool
    ) -> TmuxActionOutcome {
        guardedKill(request)
    }
}

extension TmuxControlling {
    /// Fakes that do not model ownership keep their existing launch script.
    func launchInput(
        name: String,
        directory: String,
        ownership: TmuxLaunchOwnership?
    ) -> String {
        launchInput(name: name, directory: directory)
    }

    func attachOnlyInput(name: String) -> String {
        launchInput(name: name, directory: "~")
    }

    func sessionIdentity(named name: String) -> TmuxSessionIdentity? {
        nil
    }

    func kill(identity: TmuxSessionIdentity, name: String) -> Bool {
        kill(name: name)
    }
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
        return positiveIndex(name.dropFirst(prefix.count))
    }

    private static func positiveIndex(
        _ suffix: Substring
    ) -> Int? {
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

    /// The trailing numeric index of a generated name, independent of its
    /// prefix. Migration needs the old index before the new prefix exists.
    static func trailingIndex(of name: String) -> Int? {
        guard let lastDash = name.lastIndex(of: "-") else { return nil }
        return positiveIndex(name[name.index(after: lastDash)...])
    }

    /// POSIX single-quote escaping. The input is already sanitized for
    /// session names, but directories are arbitrary user paths.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// tmux command-parser quoting, used for arguments inside an `if-shell`
    /// command string where a POSIX shell never sees the text.
    static func tmuxQuote(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        // tmux expands $variables inside double quotes.
        escaped = escaped.replacingOccurrences(of: "$", with: "\\$")
        return "\"" + escaped + "\""
    }

    /// True only for names this app generated. The tmux command parser must
    /// never receive a user-authored fragment in a command position.
    static func isSafeGeneratedName(_ name: String) -> Bool {
        !name.isEmpty
            && name.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-"
            }
    }

    /// Whether a `sonovo-*` name parses into the generated scheme. A name
    /// that fails this is `unrecognized`, never an ownership claim.
    static func parsesSessionName(_ name: String) -> Bool {
        if name.hasPrefix("sonovo-"),
           let lastDash = name.lastIndex(of: "-") {
            let prefix = String(name[..<lastDash]) + "-"
            if index(of: name, prefix: prefix) != nil {
                let beforeIndex = name[name.startIndex..<lastDash]
                if let hashDash = beforeIndex.lastIndex(of: "-") {
                    let slug = beforeIndex[beforeIndex.startIndex..<hashDash]
                    let hash = beforeIndex[beforeIndex.index(after: hashDash)...]
                    if !slug.isEmpty,
                       hash.count == 8,
                       hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) {
                        return true
                    }
                }
            }
        }
        // The demo form has no hash, so it is tried only after the normal
        // form. A real project slugged "sample" keeps its generated name.
        return name.hasPrefix("sonovo-sample-")
            && index(of: name, prefix: "sonovo-sample-") != nil
    }

    /// Full SHA-256 fingerprint for ledger continuity. The 32-bit name hash
    /// is far too weak to distinguish two owners.
    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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
        loginShell: Bool = false,
        ownership: TmuxLaunchOwnership? = nil
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
        var setup = "\(tool) set-option -s exit-unattached off "
            + "\\; new-session -d -s \(quotedName) "
            + "-c \(quotedDirectory)\(command) "
            + "\\; set-option -t \(sessionTarget) destroy-unattached off"
        if let ownership {
            // Written in the same one-client sequence that creates the
            // session, so a session never exists without its ownership proof.
            setup += " \\; set-option -t \(sessionTarget) "
                + "@sonovo_project_path \(TmuxNaming.shellQuote(ownership.projectPath))"
            setup += " \\; set-option -t \(sessionTarget) "
                // The shell evaluates this at session creation. A reused
                // launch line therefore records the new creation time.
                + "@sonovo_created_at \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
            setup += " \\; set-option -t \(sessionTarget) "
                + "@sonovo_app_version \(TmuxNaming.shellQuote(ownership.appVersion))"
        }
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

    /// Attaches an existing session in a new tab without creating it. Used by
    /// the Sessions window's attach-only Open.
    static func attachOnly(executable: String, name: String) -> String {
        let tool = commandToken(executable)
        let target = TmuxNaming.shellQuote("=" + name)
        return "exec \(tool) set-option -s exit-unattached off "
            + "\\; set-option -t \(TmuxNaming.shellQuote(name)) "
            + "destroy-unattached off "
            + "\\; attach -t \(target)\n"
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

    /// Resolved on every access so installing or removing tmux while Sonovo
    /// runs is visible to Recheck; a launch-time snapshot would pin the
    /// window to "not available" until relaunch.
    var isAvailable: Bool { executable != nil }
    private var executable: String? { executableProvider() }
    private let executableProvider: @Sendable () -> String?
    /// Explicit socket for every hygiene query. Ambient defaults would let
    /// the app address a different server than the one it reports on.
    let socketPath: String
    private static let extraPaths =
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    private static let deadline: TimeInterval = 2

    init(
        executableProvider: @escaping @Sendable () -> String? = {
            LiveTmux.resolveExecutable()
        },
        socketPath: String? = nil
    ) {
        self.executableProvider = executableProvider
        self.socketPath = socketPath ?? Self.resolveSocketPath()
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
        launchInput(name: name, directory: directory, ownership: nil)
    }

    func launchInput(
        name: String,
        directory: String,
        ownership: TmuxLaunchOwnership?
    ) -> String {
        guard let executable else { return "" }
        return TmuxCommands.open(
            executable: executable,
            name: name,
            directory: directory,
            shell: Preferences.effectiveShell,
            loginShell: Preferences.loginShell,
            ownership: ownership
        )
    }

    /// Attach-only launch input for the Sessions window's Open action.
    func attachOnlyInput(name: String) -> String {
        guard let executable else { return "" }
        return TmuxCommands.attachOnly(executable: executable, name: name)
    }

    /// A guarded kill for the no-coordinator fallback. The identity and name
    /// are checked inside the same tmux command sequence as the kill.
    func kill(identity: TmuxSessionIdentity, name: String) -> Bool {
        guard isAvailable,
              TmuxNaming.isSafeGeneratedName(name),
              let probe = hygieneRun([
                  "display-message",
                  "-p",
                  "-t", "=\(name)",
                  "#{session_id}\u{1F}#{pid}"
                    + "\u{1F}#{session_attached}\u{1F}#{session_windows}"
              ]), probe.status == 0 else {
            return false
        }
        let fields = probe.output.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).split(
            separator: TmuxSnapshotParser.fieldSeparator,
            omittingEmptySubsequences: false
        ).map(String.init)
        guard fields.count == 4,
              fields[0] == identity.sessionID,
              Int(fields[1]) == identity.server.pid,
              let attached = Int(fields[2]),
              let windows = Int(fields[3]) else {
            return false
        }
        let outcome = guardedKill(
            TmuxGuardedKill(
                identity: identity,
                name: name,
                expectedAttachedClients: attached,
                expectedWindows: windows
            )
        )
        switch outcome {
        case .ended, .absent: return true
        case .skipped, .refused, .uncertain, .notAttempted: return false
        }
    }

    /// Resolve a session's identity before the user confirms a destructive
    /// action. The guarded kill rechecks the identity server-side.
    func sessionIdentity(named name: String) -> TmuxSessionIdentity? {
        guard isAvailable,
              TmuxNaming.isSafeGeneratedName(name),
              let result = hygieneRun([
                  "display-message",
                  "-p",
                  "-t", "=\(name)",
                  "#{session_id}\u{1F}#{pid}"
              ]), result.status == 0 else {
            return nil
        }
        let fields = result.output.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).split(
            separator: TmuxSnapshotParser.fieldSeparator,
            omittingEmptySubsequences: false
        ).map(String.init)
        guard fields.count == 2,
              fields[0].hasPrefix("$"),
              fields[0].dropFirst().allSatisfy(\.isNumber),
              let pid = Int(fields[1]), pid > 0 else {
            return nil
        }
        return TmuxSessionIdentity(
            server: TmuxServerIdentity(socketPath: socketPath, pid: pid),
            sessionID: fields[0]
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

    /// Bounded and memory-only, so a wedged tmux cannot freeze the main
    /// actor, output cannot accumulate on disk, and a descendant cannot hold
    /// a temp file open.
    private static func runProcess(
        _ executable: String,
        _ arguments: [String]
    ) -> ProcessResult? {
        guard let output = BoundedProcessRunner.run(
            executable: executable,
            arguments: arguments,
            deadline: Date().addingTimeInterval(deadline),
            maxBytes: TmuxSnapshotParser.maxOutputBytes
        ) else {
            return nil
        }
        // Incomplete transport is unknown, never an empty answer.
        if output.timedOut || output.truncated || output.cancelled
            || output.drainIncomplete {
            return nil
        }
        return ProcessResult(
            status: output.status,
            output: String(
                decoding: output.stdout + output.stderr,
                as: UTF8.self
            )
        )
    }
}

// MARK: - Typed hygiene transport

struct TmuxServerIdentity: Hashable, Sendable, Codable {
    let socketPath: String
    let pid: Int
}

struct TmuxSessionIdentity: Hashable, Sendable, Codable {
    let server: TmuxServerIdentity
    let sessionID: String

    /// Stable key for persistence. The socket path can contain the separator
    /// only in theory; tmux socket names are filesystem paths.
    var key: String {
        "\(server.socketPath)\u{1F}\(server.pid)\u{1F}\(sessionID)"
    }
}

/// The app launch a snapshot belongs to. A new launch discards idle credit
/// from an older one.
struct BootIdentity: Hashable, Sendable, Codable {
    let launchID: UUID
    let startedAt: Date
}

enum ProcessObservation: String, Sendable, Codable, Equatable {
    case running
    case noCommandDetected
    case unknown
}

enum Ownership: Equatable, Sendable {
    case verified(projectPath: String)
    case unmapped
    case unrecognized

    var verifiedProjectPath: String? {
        if case let .verified(path) = self { return path }
        return nil
    }

    var isVerified: Bool { verifiedProjectPath != nil }

    var fingerprint: String {
        switch self {
        case let .verified(path): "verified:" + TmuxNaming.fingerprint(path)
        case .unmapped: "unmapped"
        case .unrecognized: "unrecognized"
        }
    }
}

struct TmuxSessionObservation: Sendable, Equatable, Identifiable {
    let name: String
    let sessionID: String
    let server: TmuxServerIdentity
    let attachedClients: Int
    let windows: Int
    let sharedWindows: Bool
    let createdAt: Date
    let lastActivity: Date
    let activePath: String?
    let ownership: Ownership
    let process: ProcessObservation
    let paneCount: Int

    var identity: TmuxSessionIdentity {
        TmuxSessionIdentity(server: server, sessionID: sessionID)
    }

    var id: TmuxSessionIdentity { identity }
    var isDetached: Bool { attachedClients == 0 }
}

enum Completeness: Sendable, Equatable {
    case complete
    case incomplete(reason: String)
    case unknown

    var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }

    var reason: String? {
        switch self {
        case .complete: nil
        case let .incomplete(reason): reason
        case .unknown: "The tmux server could not be queried."
        }
    }
}

struct TmuxSnapshot: Sendable, Equatable {
    let sessions: [TmuxSessionObservation]
    let completeness: Completeness
    let scannedAt: Date
    let boot: BootIdentity

    func session(_ identity: TmuxSessionIdentity) -> TmuxSessionObservation? {
        sessions.first { $0.identity == identity }
    }

    func session(named name: String) -> TmuxSessionObservation? {
        sessions.first { $0.name == name }
    }
}

/// A registry record proves ownership when a session's tmux metadata is
/// missing (a legacy session, or an option that was removed).
struct TmuxRegistryEntry: Sendable, Equatable, Codable {
    let projectPath: String
    let createdAt: Date?
}

struct TmuxPaneObservation: Sendable, Equatable {
    let paneID: String
    let windowIndex: Int
    let pid: Int32
    let command: String
    let path: String?
    let isActive: Bool
    let isDead: Bool

    var label: String {
        "window \(windowIndex) · \(paneID)"
            + (command.isEmpty ? "" : " · \(command)")
    }

    var address: TmuxPaneAddress {
        TmuxPaneAddress(paneID: paneID, label: label)
    }
}

struct TmuxPaneAddress: Hashable, Sendable, Codable {
    let paneID: String
    let label: String
}

struct TmuxGuardedKill: Sendable, Equatable {
    let identity: TmuxSessionIdentity
    let name: String
    let expectedAttachedClients: Int
    let expectedWindows: Int
}

enum TmuxRenameOutcome: Sendable, Equatable {
    case renamed
    case absent
    case nameTaken
    case skipped(reason: String)
    case refused(reason: String)
    case uncertain(reason: String)
}

struct TmuxGuardedRename: Sendable, Equatable {
    let identity: TmuxSessionIdentity
    let currentName: String
    let newName: String
    /// The ownership path written in the same guarded command sequence.
    let newProjectPath: String?
}

enum TmuxCaptureVerdict: String, Sendable, Codable, Equatable {
    case complete
    case truncated
    case failed
}

struct TmuxCapturePaneResult: Sendable, Equatable, Codable {
    let pane: TmuxPaneAddress
    let text: String
    let verdict: TmuxCaptureVerdict
    let reason: String?
}

struct TmuxCaptureResult: Sendable, Equatable {
    let panes: [TmuxCapturePaneResult]
    let totalBytes: Int
    let verdict: TmuxCaptureVerdict
}

enum TmuxCapturePanes {
    /// Applies the shared pane budget. The omitted count is reported so a
    /// truncated capture is visible rather than silently short.
    static func split(
        _ panes: [TmuxPaneAddress],
        max: Int
    ) -> (kept: [TmuxPaneAddress], omitted: Int) {
        let limit = Swift.max(0, max)
        let kept = Array(panes.prefix(limit))
        return (kept, Swift.max(0, panes.count - kept.count))
    }
}

enum TmuxCaptureClipper {
    /// Final composed-output clamp. Headers and separators count against
    /// the same limits as captured content.
    static func clamp(
        _ text: String,
        maxBytes: Int,
        maxLines: Int
    ) -> (text: String, lines: Int, truncated: Bool) {
        guard maxBytes > 0, maxLines > 0 else {
            return ("", 0, !text.isEmpty)
        }
        var pieces = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var truncated = false
        if pieces.count > maxLines {
            pieces = Array(pieces.prefix(maxLines))
            truncated = true
        }
        var result = pieces.joined(separator: "\n")
        if result.utf8.count > maxBytes {
            var bytes = Array(result.utf8.prefix(maxBytes))
            while !bytes.isEmpty,
                  String(bytes: bytes, encoding: .utf8) == nil {
                bytes.removeLast()
            }
            result = String(bytes: bytes, encoding: .utf8) ?? ""
            truncated = true
        }
        let lines = result.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).count
        return (result, lines, truncated)
    }
}

enum TmuxCaptureComposer {
    /// One labelled block per pane. History and visible content share a
    /// section because `capture-pane -S -` returns both; the alternate screen
    /// is always labelled separately so a reader can tell them apart.
    static func text(
        pane: TmuxPaneAddress,
        history: String,
        alternate: String?
    ) -> String {
        let alternateText = alternate ?? "(no alternate screen)"
        return "### \(pane.paneID) \(pane.label)\n"
            + "[history+visible]\n\(history)\n"
            + "[alternate]\n\(alternateText)\n"
    }
}

struct TmuxCaptureRequest: Sendable, Equatable {
    let identity: TmuxSessionIdentity
    let panes: [TmuxPaneAddress]
    let maxBytes: Int
    let maxLines: Int
    let maxPanes: Int
    let deadline: Date
}

/// The typed surface the hygiene layer uses. Every implementation is
/// responsible for its own process boundary; the app never parses a name to
/// decide ownership.
protocol TmuxHygieneServicing: Sendable {
    var isAvailable: Bool { get }
    func snapshot(
        now: Date,
        boot: BootIdentity,
        registry: [TmuxSessionIdentity: TmuxRegistryEntry]
    ) -> TmuxSnapshot
    func panes(for identity: TmuxSessionIdentity) -> [TmuxPaneObservation]?
    func guardedKill(_ request: TmuxGuardedKill) -> TmuxActionOutcome
    func guardedKill(
        _ request: TmuxGuardedKill,
        isCancelled: @Sendable () -> Bool
    ) -> TmuxActionOutcome
    func guardedRename(_ request: TmuxGuardedRename) -> TmuxRenameOutcome
    func capture(_ request: TmuxCaptureRequest) -> TmuxCaptureResult
}

struct TmuxFramingFailure: Error, Sendable, Equatable {
    let reason: String
}

enum TmuxSnapshotParser {
    static let fieldSeparator: Character = "\u{1F}"
    static let maxOutputBytes = 4 * 1024 * 1024
    static let maxRecords = 4096
    static let maxFieldBytes = 8192

    static let sessionFieldCount = 10
    static let paneFieldCount = 8
    static let windowFieldCount = 4

    /// The plan's filter expression, verified on tmux 3.8. Anchored regexes
    /// do not match in tmux's `m:` format, so this exact shape is required.
    static let filter = "#{m:sonovo-*,#{session_name}}"

    private static func separatorString() -> String {
        String(fieldSeparator)
    }

    static var sessionFormat: String {
        [
            "#{session_id}",
            "#{session_name}",
            "#{pid}",
            "#{session_attached}",
            "#{session_windows}",
            "#{session_created}",
            "#{session_activity}",
            "#{@sonovo_project_path}",
            "#{@sonovo_created_at}",
            "#{@sonovo_app_version}"
        ].joined(separator: separatorString())
    }

    static var paneFormat: String {
        [
            "#{session_id}",
            "#{pane_id}",
            "#{pane_pid}",
            "#{pane_current_command}",
            "#{pane_current_path}",
            "#{pane_active}",
            "#{pane_dead}",
            "#{window_index}"
        ].joined(separator: separatorString())
    }

    static var windowFormat: String {
        [
            "#{session_id}",
            "#{window_id}",
            "#{window_linked}",
            "#{window_linked_sessions_list}"
        ].joined(separator: separatorString())
    }

    /// Frame one tmux answer. nil text means the query itself failed. A
    /// malformed record invalidates the whole answer; it never becomes a row.
    static func records(
        from text: String?,
        fieldCount: Int
    ) -> Result<[[String]], TmuxFramingFailure> {
        guard let text else {
            return .failure(TmuxFramingFailure(reason: "The tmux query did not answer."))
        }
        guard text.utf8.count <= maxOutputBytes else {
            return .failure(TmuxFramingFailure(reason: "The tmux answer exceeded the byte cap."))
        }
        var rows: [[String]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { continue }
            let fields = line.split(
                separator: fieldSeparator,
                omittingEmptySubsequences: false
            ).map(String.init)
            guard fields.count == fieldCount else {
                return .failure(TmuxFramingFailure(reason: "A tmux record had \(fields.count) fields, expected \(fieldCount)."))
            }
            guard fields.allSatisfy({ $0.utf8.count <= maxFieldBytes }) else {
                return .failure(TmuxFramingFailure(reason: "A tmux field exceeded the field cap."))
            }
            rows.append(fields)
            if rows.count > maxRecords {
                return .failure(TmuxFramingFailure(reason: "The tmux answer exceeded the record cap."))
            }
        }
        return .success(rows)
    }

    static func sessions(
        from text: String?,
        panesText: String?,
        windowsText: String?,
        parentPIDs: Set<Int32>?,
        socketPath: String,
        registry: [TmuxSessionIdentity: TmuxRegistryEntry],
        boot: BootIdentity,
        now: Date
    ) -> TmuxSnapshot {
        let sessionRows: [[String]]
        switch records(from: text, fieldCount: sessionFieldCount) {
        case let .failure(failure):
            return TmuxSnapshot(
                sessions: [],
                completeness: text == nil ? .unknown : .incomplete(reason: failure.reason),
                scannedAt: now,
                boot: boot
            )
        case let .success(rows):
            sessionRows = rows
        }
        guard !sessionRows.isEmpty else {
            return TmuxSnapshot(
                sessions: [],
                completeness: .complete,
                scannedAt: now,
                boot: boot
            )
        }

        var completeness: Completeness = .complete
        func markIncomplete(_ reason: String) {
            if completeness.isComplete {
                completeness = .incomplete(reason: reason)
            }
        }

        let paneRecords: [(sessionID: String, pane: TmuxPaneObservation)]
        switch records(from: panesText, fieldCount: paneFieldCount) {
        case let .failure(failure):
            paneRecords = []
            markIncomplete("Pane data is incomplete: \(failure.reason)")
        case let .success(rows):
            paneRecords = rows.compactMap { fields -> (String, TmuxPaneObservation)? in
                guard let pane = decodePane(fields) else { return nil }
                return (fields[0], pane)
            }
            if paneRecords.count != rows.count {
                markIncomplete("A pane record could not be parsed.")
            }
        }

        struct WindowRecord {
            let sessionID: String
            let windowID: String
            let linked: Bool
        }
        var windowRecords: [WindowRecord] = []
        switch records(from: windowsText, fieldCount: windowFieldCount) {
        case let .failure(failure):
            markIncomplete("Window topology is incomplete: \(failure.reason)")
        case let .success(rows):
            windowRecords = rows.compactMap { fields in
                guard fields[2] == "0" || fields[2] == "1" else {
                    return nil
                }
                return WindowRecord(
                    sessionID: fields[0],
                    windowID: fields[1],
                    linked: fields[2] == "1"
                )
            }
            if windowRecords.count != rows.count {
                markIncomplete("A window record could not be parsed.")
            }
        }

        var seen: Set<String> = []
        var sessions: [TmuxSessionObservation] = []
        for fields in sessionRows {
            guard fields[0].hasPrefix("$"),
                  fields[0].dropFirst().allSatisfy(\.isNumber),
                  !fields[1].isEmpty,
                  let pid = Int(fields[2]), pid > 0,
                  let attached = Int(fields[3]), attached >= 0,
                  let windows = Int(fields[4]), windows >= 0,
                  let created = TimeInterval(fields[5]), created > 0,
                  let activity = TimeInterval(fields[6]), activity >= 0 else {
                markIncomplete("A session record failed field validation.")
                continue
            }
            guard seen.insert(fields[0]).inserted else {
                markIncomplete("A session id appeared twice.")
                continue
            }
            let sessionID = fields[0]
            let name = fields[1]
            let server = TmuxServerIdentity(socketPath: socketPath, pid: pid)
            let identity = TmuxSessionIdentity(server: server, sessionID: sessionID)
            let createdAt = Date(timeIntervalSince1970: created)

            let sessionPanes = paneRecords
                .filter { $0.sessionID == sessionID }
                .map(\.pane)
            if sessionPanes.isEmpty {
                markIncomplete("Session \(name) had no pane records.")
            }

            let process: ProcessObservation
            if sessionPanes.isEmpty {
                process = .unknown
            } else if sessionPanes.contains(where: {
                !$0.command.isEmpty
                    && !TmuxSnapshotParser.shellNames.contains(
                        ($0.command as NSString).lastPathComponent
                    )
            }) {
                process = .running
            } else if sessionPanes.contains(where: \.command.isEmpty) {
                process = .unknown
                markIncomplete(
                    "Session \(name) had a pane with no command evidence."
                )
            } else if parentPIDs == nil {
                process = .unknown
            } else if sessionPanes.contains(where: {
                parentPIDs?.contains($0.pid) == true
            }) {
                process = .running
            } else {
                process = .noCommandDetected
            }

            let sessionWindows = windowRecords.filter {
                $0.sessionID == sessionID
            }
            if sessionWindows.isEmpty {
                markIncomplete("Session \(name) had no window records.")
            }
            if Set(sessionWindows.map(\.windowID)).count != windows {
                markIncomplete(
                    "Session \(name) window records did not cover every window."
                )
            }
            if Set(sessionPanes.map(\.windowIndex)).count != windows {
                markIncomplete(
                    "Session \(name) pane records did not cover every window."
                )
            }
            let shared = sessionWindows.contains(where: \.linked)

            let metadataPath = fields[7]
            let metadataCreated = ISO8601DateFormatter().date(
                from: fields[8]
            )
            let metadataValid = !metadataPath.isEmpty
                && !fields[9].isEmpty
                && metadataCreated.map({
                    abs($0.timeIntervalSince(createdAt)) <= 5
                }) ?? false
            let ownership: Ownership
            if metadataValid {
                ownership = .verified(projectPath: metadataPath)
            } else if let entry = registry[identity],
                      entry.createdAt.map({
                          abs($0.timeIntervalSince(createdAt)) <= 2
                      }) ?? true {
                ownership = .verified(projectPath: entry.projectPath)
            } else {
                ownership = TmuxNaming.parsesSessionName(name)
                    ? .unmapped
                    : .unrecognized
            }

            let activePath = sessionPanes.first(where: \.isActive)?.path
                ?? sessionPanes.compactMap(\.path).first

            sessions.append(
                TmuxSessionObservation(
                    name: name,
                    sessionID: sessionID,
                    server: server,
                    attachedClients: attached,
                    windows: windows,
                    sharedWindows: shared,
                    createdAt: createdAt,
                    lastActivity: Date(timeIntervalSince1970: activity),
                    activePath: activePath,
                    ownership: ownership,
                    process: process,
                    paneCount: sessionPanes.count
                )
            )
        }

        sessions.sort {
            $0.name == $1.name
                ? $0.sessionID < $1.sessionID
                : $0.name < $1.name
        }
        return TmuxSnapshot(
            sessions: sessions,
            completeness: completeness,
            scannedAt: now,
            boot: boot
        )
    }

    static func panes(from text: String?) -> [TmuxPaneObservation]? {
        guard case let .success(rows) =
            records(from: text, fieldCount: paneFieldCount) else {
            return nil
        }
        var result: [TmuxPaneObservation] = []
        for fields in rows {
            guard let pane = decodePane(fields) else { return nil }
            result.append(pane)
        }
        return result
    }

    static func decodePane(_ fields: [String]) -> TmuxPaneObservation? {
        guard fields.count == paneFieldCount,
              fields[0].count > 1,
              fields[0].hasPrefix("$"),
              fields[0].dropFirst().allSatisfy(\.isNumber),
              fields[1].count > 1,
              fields[1].hasPrefix("%"),
              fields[1].dropFirst().allSatisfy(\.isNumber),
              let pid = Int32(fields[2]),
              let windowIndex = Int(fields[7]),
              fields[5] == "0" || fields[5] == "1",
              fields[6] == "0" || fields[6] == "1" else {
            return nil
        }
        return TmuxPaneObservation(
            paneID: fields[1],
            windowIndex: windowIndex,
            pid: pid,
            command: fields[3],
            path: fields[4].isEmpty ? nil : fields[4],
            isActive: fields[5] == "1",
            isDead: fields[6] == "1"
        )
    }

    nonisolated static let shellNames: Set<String> = [
        "zsh", "bash", "fish", "sh", "login", "tmux"
    ]
}

// MARK: - Bounded memory-only process transport

/// Reads a child's stdout and stderr through pipes, concurrently, under a
/// shared byte cap and a monotonic deadline. It never creates a file, which
/// is what makes it safe for terminal content.
enum BoundedProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
        let truncated: Bool
        let timedOut: Bool
        let cancelled: Bool
        let drainIncomplete: Bool
    }

    /// One allowance for both streams, so stdout + stderr together never
    /// exceed the documented hard byte cap.
    private final class Allowance: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        private var truncated = false

        init(cap: Int) {
            remaining = Swift.max(0, cap)
        }

        func claim(_ count: Int) -> Int {
            lock.lock()
            defer { lock.unlock() }
            let granted = Swift.min(count, remaining)
            remaining -= granted
            if granted < count { truncated = true }
            return granted
        }

        var isTruncated: Bool {
            lock.lock()
            defer { lock.unlock() }
            return truncated
        }
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private let allowance: Allowance
        private var storage = Data()
        private var readFailed = false

        init(allowance: Allowance) {
            self.allowance = allowance
        }

        var isTruncated: Bool { allowance.isTruncated }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        var didReadFail: Bool {
            lock.lock()
            defer { lock.unlock() }
            return readFailed
        }

        func markReadFailed() {
            lock.lock()
            readFailed = true
            lock.unlock()
        }

        func append(_ chunk: Data) {
            let granted = allowance.claim(chunk.count)
            guard granted > 0 else { return }
            lock.lock()
            defer { lock.unlock() }
            storage.append(chunk.prefix(granted))
        }
    }

    static func run(
        executable: String,
        arguments: [String],
        deadline: Date,
        maxBytes: Int,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> Output? {
        // This runner polls, sleeps, and waits for termination by design.
        // Calling it from the main thread would freeze the UI for the whole
        // deadline; every production caller is already off-actor.
        precondition(
            !Thread.isMainThread,
            "BoundedProcessRunner.run blocks; call it off the main thread"
        )
        let budget = deadline.timeIntervalSinceNow
        guard maxBytes > 0, budget > 0 else { return nil }
        // Convert the caller's wall-clock deadline to a monotonic instant.
        let monotonicEnd = DispatchTime.now()
            + .milliseconds(Int(budget * 1000))

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = environment["PATH"].map {
            "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\($0)"
        } ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let allowance = Allowance(cap: maxBytes)
        let stdoutBox = Buffer(allowance: allowance)
        let stderrBox = Buffer(allowance: allowance)
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)

        drain(stdoutPipe.fileHandleForReading, into: stdoutBox, group: group, queue: queue)
        drain(stderrPipe.fileHandleForReading, into: stderrBox, group: group, queue: queue)

        do {
            try process.run()
        } catch {
            return nil
        }

        var timedOut = false
        var cancelled = false
        while process.isRunning {
            if isCancelled() {
                cancelled = true
                break
            }
            if DispatchTime.now() >= monotonicEnd {
                timedOut = true
                break
            }
            if stdoutBox.isTruncated || stderrBox.isTruncated {
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        if process.isRunning {
            process.terminate()
            let stop = DispatchTime.now() + .milliseconds(500)
            while process.isRunning, DispatchTime.now() < stop {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                let hardStop = DispatchTime.now() + .milliseconds(500)
                while process.isRunning, DispatchTime.now() < hardStop {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }

        var drainIncomplete = false
        let now = DispatchTime.now()
        let remaining = now.uptimeNanoseconds < monotonicEnd.uptimeNanoseconds
            ? Double(monotonicEnd.uptimeNanoseconds - now.uptimeNanoseconds)
                / 1_000_000_000
            : 0
        if remaining > 0 {
            let limit = Swift.min(remaining, 0.5)
            if group.wait(
                timeout: .now() + .milliseconds(Int(limit * 1000))
            ) == .timedOut {
                drainIncomplete = true
            }
        } else {
            drainIncomplete = true
        }
        if drainIncomplete {
            // The stream may have lost output; fail closed even if closing
            // the read ends releases the drain threads. Do not wait past the
            // deadline: the buffers are lock-protected and the result is
            // already marked incomplete.
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }
        if stdoutBox.didReadFail || stderrBox.didReadFail {
            drainIncomplete = true
        }

        let status: Int32 = process.isRunning ? -1 : process.terminationStatus
        return Output(
            status: status,
            stdout: stdoutBox.data,
            stderr: stderrBox.data,
            truncated: allowance.isTruncated,
            timedOut: timedOut,
            cancelled: cancelled,
            drainIncomplete: drainIncomplete
        )
    }

    nonisolated private static func drain(
        _ handle: FileHandle,
        into box: Buffer,
        group: DispatchGroup,
        queue: DispatchQueue
    ) {
        group.enter()
        queue.async {
            defer { group.leave() }
            while true {
                let chunk: Data?
                do {
                    chunk = try handle.read(upToCount: 64 * 1024)
                } catch {
                    box.markReadFailed()
                    break
                }
                guard let chunk, !chunk.isEmpty else { break }
                box.append(chunk)
                if box.isTruncated { break }
            }
        }
    }
}

// MARK: - Live typed transport

extension LiveTmux: TmuxHygieneServicing {
    private static func resolveSocketPath() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let tmux = environment["TMUX"],
           let first = tmux.split(separator: ",", maxSplits: 1).first,
           !first.isEmpty {
            return URL(fileURLWithPath: String(first))
                .resolvingSymlinksInPath()
                .path
        }
        let base = environment["TMUX_TMPDIR"] ?? "/tmp"
        return URL(fileURLWithPath: base)
            .appendingPathComponent("tmux-\(getuid())/default")
            .resolvingSymlinksInPath()
            .path
    }

    private func hygieneRun(_ arguments: [String]) -> ProcessResult? {
        guard let executable else { return nil }
        return Self.runProcess(
            executable,
            ["-S", socketPath] + arguments
        )
    }

    func snapshot(
        now: Date,
        boot: BootIdentity,
        registry: [TmuxSessionIdentity: TmuxRegistryEntry]
    ) -> TmuxSnapshot {
        guard isAvailable else {
            return TmuxSnapshot(
                sessions: [],
                completeness: .unknown,
                scannedAt: now,
                boot: boot
            )
        }
        guard let sessions = hygieneRun([
            "list-sessions",
            "-f", TmuxSnapshotParser.filter,
            "-F", TmuxSnapshotParser.sessionFormat
        ]) else {
            return TmuxSnapshot(
                sessions: [],
                completeness: .unknown,
                scannedAt: now,
                boot: boot
            )
        }
        if sessions.status != 0 {
            if sessions.output.lowercased().contains("no server running") {
                return TmuxSnapshot(
                    sessions: [],
                    completeness: .complete,
                    scannedAt: now,
                    boot: boot
                )
            }
            return TmuxSnapshot(
                sessions: [],
                completeness: .unknown,
                scannedAt: now,
                boot: boot
            )
        }
        let panes = hygieneRun([
            "list-panes",
            "-a",
            "-f", TmuxSnapshotParser.filter,
            "-F", TmuxSnapshotParser.paneFormat
        ])
        let windows = hygieneRun([
            "list-windows",
            "-a",
            "-f", TmuxSnapshotParser.filter,
            "-F", TmuxSnapshotParser.windowFormat
        ])
        return TmuxSnapshotParser.sessions(
            from: sessions.output,
            panesText: panes?.status == 0 ? panes?.output : nil,
            windowsText: windows?.status == 0 ? windows?.output : nil,
            parentPIDs: Self.parentPIDs(),
            socketPath: socketPath,
            registry: registry,
            boot: boot,
            now: now
        )
    }

    func panes(
        for identity: TmuxSessionIdentity
    ) -> [TmuxPaneObservation]? {
        guard isAvailable,
              identity.sessionID.hasPrefix("$"),
              identity.sessionID.dropFirst().allSatisfy(\.isNumber),
              identity.server.pid > 0 else {
            return nil
        }
        guard let result = hygieneRun([
            "list-panes",
            "-a",
            "-f", "#{&&:#{==:#{session_id},\(identity.sessionID)},"
                + "#{==:#{pid},\(identity.server.pid)}}",
            "-F", TmuxSnapshotParser.paneFormat
        ]), result.status == 0,
        let panes = TmuxSnapshotParser.panes(from: result.output),
        !panes.isEmpty else {
            return nil
        }
        return panes
    }

    func guardedKill(_ request: TmuxGuardedKill) -> TmuxActionOutcome {
        guardedKill(request, isCancelled: { false })
    }

    func guardedKill(
        _ request: TmuxGuardedKill,
        isCancelled: @Sendable () -> Bool
    ) -> TmuxActionOutcome {
        guard !isCancelled() else {
            return .notAttempted(reason: "The action was cancelled.")
        }
        guard isAvailable, let executable else {
            return .uncertain(reason: "tmux is unavailable.")
        }
        guard TmuxNaming.isSafeGeneratedName(request.name),
              request.identity.server.pid > 0,
              request.identity.sessionID.hasPrefix("$"),
              request.identity.sessionID.dropFirst().allSatisfy(\.isNumber),
              request.expectedAttachedClients >= 0,
              request.expectedWindows >= 0 else {
            return .refused(reason: "The session identity was not trustworthy.")
        }
        let sid = request.identity.sessionID

        guard !isCancelled() else {
            return .notAttempted(reason: "The action was cancelled.")
        }
        // The topology precheck is a fresh query immediately before dispatch.
        // tmux has no session-wide linked-window format for the guard itself;
        // a linkage change inside the gap is the documented residual race.
        guard let linked = hygieneRun([
            "list-windows",
            "-a",
            "-f", "#{&&:#{==:#{session_id},\(sid)},#{window_linked}}",
            "-F", "#{window_id}"
        ]), linked.status == 0 else {
            return .uncertain(reason: "The shared-window check failed.")
        }
        if !linked.output.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            return .refused(reason: "A window is shared with another session.")
        }

        let condition = "#{&&:"
            + "#{==:#{pid},\(request.identity.server.pid)},"
            + "#{==:#{session_id},\(sid)},"
            + "#{==:#{session_name},\(request.name)},"
            + "#{==:#{session_attached},\(request.expectedAttachedClients)},"
            + "#{==:#{session_windows},\(request.expectedWindows)}}"
        let tool = executable
        guard let result = BoundedProcessRunner.run(
            executable: tool,
            arguments: [
                "-S", socketPath,
                "if-shell", "-F", "-t", sid, condition,
                "kill-session -t \(sid)",
                "display-message -p sonovo-guard-refused"
            ],
            deadline: Date().addingTimeInterval(2),
            maxBytes: 64 * 1024
        ) else {
            return .uncertain(reason: "The tmux guard did not answer.")
        }
        if result.timedOut || result.truncated || result.cancelled
            || result.drainIncomplete {
            return .uncertain(reason: "The tmux guard result was incomplete.")
        }
        let output = String(decoding: result.stdout + result.stderr, as: UTF8.self)
        if output.contains("sonovo-guard-refused") {
            switch sessionExistsByID(sid) {
            case true?: return .skipped(reason: "The session changed before it could be ended.")
            case false?: return .absent
            case nil: return .uncertain(reason: "The session could not be rechecked.")
            }
        }
        if result.status == 0 {
            return .ended
        }
        if output.contains("can't find session")
            || output.contains("no such session")
            || output.lowercased().contains("no server running") {
            return .absent
        }
        return .uncertain(
            reason: output.isEmpty ? "The tmux guard failed." : output
        )
    }

    private func sessionExistsByID(_ sessionID: String) -> Bool? {
        guard let result = hygieneRun([
            "has-session", "-t", sessionID
        ]) else {
            return nil
        }
        if result.status == 0 { return true }
        if result.output.contains("can't find session")
            || result.output.contains("no such session")
            || result.output.lowercased().contains("no server running") {
            return false
        }
        return nil
    }

    func guardedRename(_ request: TmuxGuardedRename) -> TmuxRenameOutcome {
        guard isAvailable, let executable else {
            return .uncertain(reason: "tmux is unavailable.")
        }
        guard TmuxNaming.isSafeGeneratedName(request.currentName),
              TmuxNaming.isSafeGeneratedName(request.newName),
              request.identity.server.pid > 0,
              request.identity.sessionID.hasPrefix("$"),
              request.identity.sessionID.dropFirst().allSatisfy(\.isNumber) else {
            return .refused(reason: "The rename identity was not trustworthy.")
        }
        let sid = request.identity.sessionID
        var command = "rename-session -t \(sid) \(request.newName)"
        if let path = request.newProjectPath {
            command += " ; set-option -t \(request.newName) "
                + "@sonovo_project_path \(TmuxNaming.tmuxQuote(path))"
        }
        let condition = "#{&&:"
            + "#{==:#{pid},\(request.identity.server.pid)},"
            + "#{==:#{session_id},\(sid)},"
            + "#{==:#{session_name},\(request.currentName)},"
            + "#{==:#{session_attached},0}}"
        guard let result = BoundedProcessRunner.run(
            executable: executable,
            arguments: [
                "-S", socketPath,
                "if-shell", "-F", "-t", sid, condition,
                command,
                "display-message -p sonovo-guard-refused"
            ],
            deadline: Date().addingTimeInterval(2),
            maxBytes: 64 * 1024
        ) else {
            return .uncertain(reason: "The tmux guard did not answer.")
        }
        if result.timedOut || result.truncated || result.cancelled
            || result.drainIncomplete {
            return .uncertain(reason: "The tmux guard result was incomplete.")
        }
        let output = String(decoding: result.stdout + result.stderr, as: UTF8.self)
        // The refusal branch exits zero, so the marker must win over status.
        if output.contains("sonovo-guard-refused") {
            switch sessionExistsByID(sid) {
            case true?: return .skipped(reason: "The session changed before it could be renamed.")
            case false?: return .absent
            case nil: return .uncertain(reason: "The session could not be rechecked.")
            }
        }
        if result.status == 0 {
            return .renamed
        }
        if output.lowercased().contains("duplicate session")
            || output.lowercased().contains("already exists") {
            return .nameTaken
        }
        if output.contains("can't find session")
            || output.contains("no such session")
            || output.lowercased().contains("no server running") {
            return .absent
        }
        return .uncertain(
            reason: output.isEmpty ? "The tmux guard failed." : output
        )
    }

    func capture(_ request: TmuxCaptureRequest) -> TmuxCaptureResult {
        guard isAvailable, let executable else {
            return failedCapture(request, reason: "tmux is unavailable.")
        }
        guard request.identity.server.pid > 0,
              request.identity.sessionID.hasPrefix("$"),
              request.identity.sessionID.dropFirst().allSatisfy(\.isNumber)
        else {
            return failedCapture(
                request,
                reason: "The capture identity was not trustworthy."
            )
        }

        var results: [TmuxCapturePaneResult] = []
        var budget = CaptureBudget(
            maxBytes: request.maxBytes,
            maxLines: request.maxLines
        )
        let split = TmuxCapturePanes.split(
            request.panes,
            max: request.maxPanes
        )
        for pane in split.kept {
            if Date() >= request.deadline {
                results.append(
                    TmuxCapturePaneResult(
                        pane: pane,
                        text: "",
                        verdict: .failed,
                        reason: "The capture deadline was reached."
                    )
                )
                continue
            }
            guard let allocation = budget.allocation() else {
                results.append(
                    TmuxCapturePaneResult(
                        pane: pane,
                        text: "",
                        verdict: .truncated,
                        reason: "The shared capture budget was exhausted."
                    )
                )
                continue
            }
            let result = capturePane(
                pane,
                request: request,
                executable: executable,
                remainingBytes: allocation.bytes,
                remainingLines: allocation.lines
            )
            results.append(result)
            budget.consume(result)
        }
        appendOmittedPanes(
            split.omitted,
            request: request,
            budget: budget,
            results: &results
        )
        return TmuxCaptureResult(
            panes: results,
            totalBytes: results.reduce(0) { $0 + $1.text.utf8.count },
            verdict: captureVerdict(for: results)
        )
    }

    private struct CaptureBudget {
        let maxBytes: Int
        let maxLines: Int
        private(set) var usedBytes = 0
        private(set) var usedLines = 0

        func allocation() -> (bytes: Int, lines: Int)? {
            let bytes = Swift.max(0, maxBytes - usedBytes)
            let lines = Swift.max(0, maxLines - usedLines)
            guard bytes > 0, lines > 0 else { return nil }
            return (bytes, lines)
        }

        mutating func consume(_ result: TmuxCapturePaneResult) {
            usedBytes += result.text.utf8.count
            usedLines += result.text.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).count
        }
    }

    private func failedCapture(
        _ request: TmuxCaptureRequest,
        reason: String
    ) -> TmuxCaptureResult {
        TmuxCaptureResult(
            panes: request.panes.map {
                TmuxCapturePaneResult(
                    pane: $0,
                    text: "",
                    verdict: .failed,
                    reason: reason
                )
            },
            totalBytes: 0,
            verdict: .failed
        )
    }

    private func appendOmittedPanes(
        _ omitted: Int,
        request: TmuxCaptureRequest,
        budget: CaptureBudget,
        results: inout [TmuxCapturePaneResult]
    ) {
        guard omitted > 0 else { return }
        let pane = TmuxPaneAddress(paneID: "omitted", label: "Pane budget")
        let text = TmuxCaptureComposer.text(
            pane: pane,
            history: "[panes omitted: \(omitted)]",
            alternate: nil
        )
        let remaining = budget.allocation()
        let clamped = TmuxCaptureClipper.clamp(
            text,
            maxBytes: remaining?.bytes ?? 0,
            maxLines: remaining?.lines ?? 0
        )
        results.append(
            TmuxCapturePaneResult(
                pane: pane,
                text: clamped.text,
                verdict: .truncated,
                reason: "The pane budget was exhausted."
            )
        )
    }

    private func captureVerdict(
        for results: [TmuxCapturePaneResult]
    ) -> TmuxCaptureVerdict {
        if results.isEmpty
            || results.contains(where: { $0.verdict == .failed }) {
            return .failed
        }
        if results.contains(where: { $0.verdict == .truncated }) {
            return .truncated
        }
        return .complete
    }

    /// Captures one pane under the shared budget. The final composed text is
    /// clamped, so framing markers cannot push the output over a limit.
    private func capturePane(
        _ pane: TmuxPaneAddress,
        request: TmuxCaptureRequest,
        executable: String,
        remainingBytes: Int,
        remainingLines: Int
    ) -> TmuxCapturePaneResult {
        let history = captureSection(
            executable: executable,
            identity: request.identity,
            paneID: pane.paneID,
            alternate: false,
            deadline: request.deadline,
            maxBytes: remainingBytes
        )
        var historyText = ""
        var historyVerdict: TmuxCaptureVerdict = .complete
        var historyReason: String?
        switch history {
        case let .content(text, verdict, reason):
            historyText = text
            historyVerdict = verdict
            historyReason = reason
        case .absent:
            historyVerdict = .failed
            historyReason = "The pane did not answer."
        }

        let alternateCap = Swift.max(
            0,
            remainingBytes - historyText.utf8.count
        )
        let alternate: CaptureSection
        if alternateCap > 0 {
            alternate = captureSection(
                executable: executable,
                identity: request.identity,
                paneID: pane.paneID,
                alternate: true,
                deadline: request.deadline,
                maxBytes: alternateCap
            )
        } else {
            alternate = .content(
                "",
                .truncated,
                "The shared capture budget was exhausted."
            )
        }
        var alternateText = "(no alternate screen)"
        var alternateVerdict: TmuxCaptureVerdict = .complete
        var alternateReason: String?
        switch alternate {
        case let .content(text, verdict, reason):
            alternateText = text
            alternateVerdict = verdict
            alternateReason = reason
        case .absent:
            alternateText = "(no alternate screen)"
        }

        var verdict: TmuxCaptureVerdict = .complete
        var reasons: [String] = []
        if historyVerdict == .failed || alternateVerdict == .failed {
            verdict = .failed
        } else if historyVerdict == .truncated
                    || alternateVerdict == .truncated {
            verdict = .truncated
        }
        if let historyReason { reasons.append(historyReason) }
        if let alternateReason { reasons.append(alternateReason) }

        let clamped = TmuxCaptureClipper.clamp(
            TmuxCaptureComposer.text(
                pane: pane,
                history: historyText,
                alternate: alternateText
            ),
            maxBytes: remainingBytes,
            maxLines: remainingLines
        )
        if clamped.truncated {
            if verdict == .complete {
                verdict = .truncated
            }
            reasons.append("The final capture budget truncated the pane.")
        }
        return TmuxCapturePaneResult(
            pane: pane,
            text: clamped.text,
            verdict: verdict,
            reason: reasons.isEmpty ? nil : reasons.joined(separator: " ")
        )
    }

    private enum CaptureSection {
        case content(String, TmuxCaptureVerdict, String?)
        case absent
    }

    /// Runs capture-pane inside one if-shell guard. The condition binds the
    /// capture to the server pid and session id, so a restarted server that
    /// reused an id cannot deliver another session's content.
    private func captureSection(
        executable: String,
        identity: TmuxSessionIdentity,
        paneID: String,
        alternate: Bool,
        deadline: Date,
        maxBytes: Int
    ) -> CaptureSection {
        guard maxBytes > 0 else {
            return .content(
                "",
                .truncated,
                "The shared capture budget was exhausted."
            )
        }
        guard paneID.hasPrefix("%"),
              paneID.dropFirst().allSatisfy(\.isNumber) else {
            return .content("", .failed, "The pane id was not trustworthy.")
        }
        let marker = "sonovo-capture-refused-\(UUID().uuidString)"
        let command = alternate
            ? "capture-pane -p -a -t \(paneID)"
            : "capture-pane -p -J -t \(paneID) -S -"
        let condition = "#{&&:#{==:#{pid},\(identity.server.pid)},"
            + "#{==:#{session_id},\(identity.sessionID)},"
            + "#{==:#{pane_id},\(paneID)}}"
        guard let output = BoundedProcessRunner.run(
            executable: executable,
            arguments: [
                "-S", socketPath,
                "if-shell", "-F", "-t", paneID, condition,
                command,
                "display-message -p \(marker)"
            ],
            deadline: deadline,
            maxBytes: maxBytes,
            isCancelled: { Task.isCancelled }
        ) else {
            return .content("", .failed, "The capture did not finish.")
        }
        let text = String(decoding: output.stdout, as: UTF8.self)
        if text.contains(marker) {
            return .content(
                "",
                .failed,
                "The session identity changed before capture."
            )
        }
        if output.cancelled {
            return .content(
                text,
                text.isEmpty ? .failed : .truncated,
                "The capture was cancelled."
            )
        }
        if output.drainIncomplete {
            return .content(
                text,
                text.isEmpty ? .failed : .truncated,
                "The capture stream did not drain."
            )
        }
        if output.status != 0 {
            let error = String(decoding: output.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if error.contains("no alternate screen") {
                return .absent
            }
            return .content(
                text,
                .failed,
                error.isEmpty ? "capture-pane failed." : error
            )
        }
        if output.timedOut {
            return text.isEmpty
                ? .content("", .failed, "The capture deadline was reached.")
                : .content(
                    text,
                    .truncated,
                    "The capture deadline was reached."
                )
        }
        if output.truncated {
            return .content(
                text,
                .truncated,
                "The byte budget truncated the capture."
            )
        }
        return .content(text, .complete, nil)
    }
}
