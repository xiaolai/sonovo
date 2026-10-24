import CoreGraphics
import Darwin
import Foundation

/// UserDefaults keys shared by Settings and the features they control.
enum PreferenceKey {
    static let restoreTabs = "sonovo.restoreTabs"
    static let reopenLast = "sonovo.reopenLast"
    static let editorFontSize = "sonovo.editorFontSize"
    static let showBreadcrumbs = "sonovo.showBreadcrumbs"
    static let wrapLines = "sonovo.wrapLines"
    static let audioDevice = "sonovo.audioDevice"
    static let followPlayhead = "sonovo.followPlayhead"
    static let captionsDefault = "sonovo.captionsDefault"
    static let shell = "sonovo.shell"
    static let terminalFont = "sonovo.terminalFont"
    static let loginShell = "sonovo.loginShell"
    static let theme = "sonovo.theme"
    static let foregroundIntensity = "sonovo.foregroundIntensity"
    static let backgroundIntensity = "sonovo.backgroundIntensity"
    static let readingTheme = "sonovo.readingTheme"
    static let readingBodySize = "sonovo.readingBodySize"
    static let readingMeasure = "sonovo.readingMeasure"
    /// Bumped by Settings after user theme files change, so open documents
    /// rebuild their resolved theme instead of serving a cached one.
    static let readingThemeRevision = "sonovo.readingThemeRevision"
}

/// Typed reads for features that cannot use `@AppStorage`. Observable UI
/// (Settings, the reading view) reads and writes the same `PreferenceKey`
/// values through `@AppStorage`, so one key drives both paths.
enum Preferences {
    static var defaults: UserDefaults { .standard }

    /// Unit tests run against a developer's real defaults unless reads are
    /// pinned; a toggled setting must not change test behavior.
    private static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"]
            != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static func bool(_ key: String, default fallback: Bool) -> Bool {
        guard !isTesting else { return fallback }
        return defaults.object(forKey: key) as? Bool ?? fallback
    }

    static var restoreTabs: Bool {
        bool(PreferenceKey.restoreTabs, default: true)
    }

    static var reopenLast: Bool {
        bool(PreferenceKey.reopenLast, default: true)
    }

    static var showBreadcrumbs: Bool {
        bool(PreferenceKey.showBreadcrumbs, default: true)
    }

    static var wrapLines: Bool {
        bool(PreferenceKey.wrapLines, default: true)
    }

    static var followPlayhead: Bool {
        bool(PreferenceKey.followPlayhead, default: true)
    }

    static var captionsDefault: Bool {
        bool(PreferenceKey.captionsDefault, default: true)
    }

    static var loginShell: Bool {
        bool(PreferenceKey.loginShell, default: true)
    }

    /// Clamps a persisted reading size before any arithmetic or `Int`
    /// conversion. Non-finite and non-positive values fall back to the theme
    /// size.
    static func clampedEditorFontSize(_ value: Double) -> CGFloat {
        guard value.isFinite, value > 0 else {
            return AppTheme.Reading.sourceSize
        }
        let range = AppTheme.Preferences.editorFontSizeRange
        return CGFloat(min(max(value, range.lowerBound), range.upperBound))
    }

    /// The reading-editor size. Zero or a missing value means the theme size.
    static var editorFontSize: CGFloat {
        guard !isTesting else { return AppTheme.Reading.sourceSize }
        return clampedEditorFontSize(
            defaults.double(forKey: PreferenceKey.editorFontSize)
        )
    }

    static var shell: String {
        guard !isTesting,
              let value = defaults.string(forKey: PreferenceKey.shell),
              value.hasPrefix("/") else {
            return ""
        }
        return value
    }

    static var terminalFont: String {
        guard !isTesting else { return "SF Mono 12" }
        return defaults.string(forKey: PreferenceKey.terminalFont)
            ?? "SF Mono 12"
    }

    /// The account's login shell. "System Default" resolves here so the
    /// login-shell toggle has an effect without an explicit choice.
    static var systemShell: String {
        TerminalShell.accountShell
    }

    /// The shell handed to Ghostty and tmux. Never empty, and never a path
    /// that cannot run: a shell removed after it was chosen falls back to
    /// the account shell instead of leaving the pane unable to start.
    static var effectiveShell: String {
        TerminalShell.resolve(shell)
    }

    /// Whether the stored shell is set but unusable.
    static var shellIsMissing: Bool {
        TerminalShell.isMissing(shell)
    }

    /// The CoreAudio device UID, or nil for the system default. Older builds
    /// stored display names ("System Default", "AirPods"); those are not
    /// UIDs, so they fall back to the default device.
    static var audioDeviceUID: String? {
        guard !isTesting else { return nil }
        let legacyNames: Set<String> = [
            "System Default", "Mac Studio Speakers", "AirPods"
        ]
        guard let value = defaults.string(forKey: PreferenceKey.audioDevice),
              !value.isEmpty,
              !legacyNames.contains(value) else {
            return nil
        }
        return value
    }
}

extension Notification.Name {
    /// Posted when a preference that live editors observe changes.
    static let sonovoEditorPreferencesChanged = Notification.Name(
        "sonovo.editorPreferencesChanged"
    )
}
