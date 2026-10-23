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
}

/// Typed reads of every preference a feature consumes. Settings writes the
/// same keys with `@AppStorage`, so a change reaches new editors, terminals,
/// and windows without a separate preferences model.
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

    /// The shell handed to Ghostty and tmux. Never empty: the account shell
    /// supplies the default.
    static var effectiveShell: String {
        let configured = shell
        return configured.isEmpty ? systemShell : configured
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
