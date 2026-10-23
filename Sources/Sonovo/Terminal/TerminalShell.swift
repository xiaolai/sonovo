import Foundation

/// Shell choices the terminal can actually start.
///
/// A stored path is untrusted: it can name a shell that was never installed,
/// moved, or deleted, and a missing binary leaves a tmux tab with a pane
/// that exits before the client can attach. Every read resolves through
/// `resolve`, which falls back to the account shell.
enum TerminalShell {
    struct Option: Identifiable, Hashable {
        /// Absolute path, or "" for the account shell.
        let path: String
        let title: String

        var id: String { path }
    }

    /// The account shell every fallback uses.
    static var accountShell: String {
        if let entry = getpwuid(getuid()),
           let shell = entry.pointee.pw_shell {
            let value = String(cString: shell)
            if value.hasPrefix("/") { return value }
        }
        if let value = ProcessInfo.processInfo.environment["SHELL"],
           value.hasPrefix("/") {
            return value
        }
        return "/bin/zsh"
    }

    /// Known shells that are present and executable, in display order.
    static func available(
        fileManager: FileManager = .default
    ) -> [Option] {
        let candidates: [(title: String, paths: [String])] = [
            ("zsh", ["/bin/zsh"]),
            ("bash", ["/bin/bash", "/opt/homebrew/bin/bash"]),
            ("fish", ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"])
        ]
        return candidates.compactMap { candidate in
            guard let path = candidate.paths.first(where: {
                isUsable($0, fileManager: fileManager)
            }) else {
                return nil
            }
            return Option(path: path, title: candidate.title)
        }
    }

    /// A regular executable file. A directory or a script without the
    /// execute bit is not a shell the terminal can start.
    static func isUsable(
        _ path: String,
        fileManager: FileManager = .default
    ) -> Bool {
        guard path.hasPrefix("/") else { return false }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }

    /// The shell the terminal starts: the configured path when it can run,
    /// otherwise the account shell.
    static func resolve(
        _ configured: String,
        fileManager: FileManager = .default
    ) -> String {
        guard !configured.isEmpty else { return accountShell }
        return isUsable(configured, fileManager: fileManager)
            ? configured
            : accountShell
    }

    /// Whether a non-empty configured path is missing or not executable.
    static func isMissing(
        _ configured: String,
        fileManager: FileManager = .default
    ) -> Bool {
        !configured.isEmpty && !isUsable(configured, fileManager: fileManager)
    }
}
