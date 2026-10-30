import Foundation

/// Writes the Settings terminal choices into a Ghostty configuration file.
/// The C API has no config setter, so loading a file is the supported way to
/// apply a font family, size, and the shell command for new surfaces.
enum TerminalPreferences {
    /// Whether new terminal tabs use tmux. Off by default: persistence is
    /// opt-in, so a new tab is a plain shell unless the user asks for a
    /// session.
    static let tmuxKey = "sonovo.terminals.tmux"

    static func tmuxEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: tmuxKey) as? Bool ?? false
    }

    /// Writes the override file and returns its path. The file is only
    /// rewritten when its contents change.
    static func overrideConfigURL() -> URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let directory = support.appendingPathComponent(
            "Sonovo",
            isDirectory: true
        )
        let url = directory.appendingPathComponent(
            "terminal-preferences.conf"
        )
        let text = configText()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            if (try? String(contentsOf: url, encoding: .utf8)) != text {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            return url
        } catch {
            return nil
        }
    }

    static func configText() -> String {
        var lines: [String] = []
        if let font = parsedFont {
            lines.append("font-family = \(sanitize(font.family))")
            lines.append("font-size = \(String(format: "%.1f", font.size))")
        }
        var command = Preferences.effectiveShell
        if Preferences.loginShell {
            command += " -l"
        }
        lines.append("command = \(sanitize(command))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Splits "SF Mono 12" into a family and a size. A value without a
    /// trailing number is a family at the default size.
    static var parsedFont: (family: String, size: Double)? {
        parsedFont(from: Preferences.terminalFont)
    }

    /// The pure split behind `parsedFont`, exposed for tests.
    static func parsedFont(
        from value: String
    ) -> (family: String, size: Double)? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ")
        guard parts.count >= 2, let size = Double(parts.last!) else {
            return (trimmed, 12)
        }
        let family = parts.dropLast().joined(separator: " ")
        return family.isEmpty ? nil : (family, size)
    }

    /// Config values are line-oriented; a newline would inject an option.
    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
