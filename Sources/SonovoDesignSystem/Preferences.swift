import CoreGraphics
import Darwin
import Foundation

/// UserDefaults keys shared by Settings and the features they control.
/// Typed reads for features that cannot use `@AppStorage`. Observable UI
/// (Settings, the reading view) reads and writes the same `PreferenceKey`
/// values through `@AppStorage`, so one key drives both paths.
package enum Preferences {
    package static var defaults: UserDefaults { .standard }

    /// Unit tests run against a developer's real defaults unless reads are
    /// pinned; a toggled setting must not change test behavior.
    private static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"]
            != nil
            || NSClassFromString("XCTestCase") != nil
    }

    package static func bool(_ key: String, default fallback: Bool) -> Bool {
        guard !isTesting else { return fallback }
        return defaults.object(forKey: key) as? Bool ?? fallback
    }

    package static var restoreTabs: Bool {
        bool(PreferenceKey.restoreTabs, default: true)
    }

    package static var reopenLast: Bool {
        bool(PreferenceKey.reopenLast, default: true)
    }

    package static var showBreadcrumbs: Bool {
        bool(PreferenceKey.showBreadcrumbs, default: true)
    }

    package static var wrapLines: Bool {
        bool(PreferenceKey.wrapLines, default: true)
    }

    package static var markdownFocusMode: Bool {
        bool(PreferenceKey.markdownFocusMode, default: false)
    }

    package static var markdownTypewriter: Bool {
        bool(PreferenceKey.markdownTypewriter, default: false)
    }

    package static var markdownLineNumbers: Bool {
        bool(PreferenceKey.markdownLineNumbers, default: false)
    }

    package static var followPlayhead: Bool {
        bool(PreferenceKey.followPlayhead, default: true)
    }

    package static var captionsDefault: Bool {
        bool(PreferenceKey.captionsDefault, default: true)
    }

    package static var loginShell: Bool {
        bool(PreferenceKey.loginShell, default: true)
    }

    /// Clamps a persisted reading size before any arithmetic or `Int`
    /// conversion. Non-finite and non-positive values fall back to the theme
    /// size.
    package static func clampedEditorFontSize(_ value: Double) -> CGFloat {
        guard value.isFinite, value > 0 else {
            return AppTheme.Reading.sourceSize
        }
        let range = AppTheme.Preferences.editorFontSizeRange
        return CGFloat(min(max(value, range.lowerBound), range.upperBound))
    }

    /// The reading-editor size. Zero or a missing value means the theme size.
    package static var editorFontSize: CGFloat {
        guard !isTesting else { return AppTheme.Reading.sourceSize }
        return clampedEditorFontSize(
            defaults.double(forKey: PreferenceKey.editorFontSize)
        )
    }

    package static var shell: String {
        guard !isTesting,
              let value = defaults.string(forKey: PreferenceKey.shell),
              value.hasPrefix("/") else {
            return ""
        }
        return value
    }

    package static var terminalFont: String {
        guard !isTesting else { return "SF Mono 12" }
        return defaults.string(forKey: PreferenceKey.terminalFont)
            ?? "SF Mono 12"
    }

    /// The CoreAudio device UID, or nil for the system default. Older builds
    /// stored display names ("System Default", "AirPods"); those are not
    /// UIDs, so they fall back to the default device.
    package static var audioDeviceUID: String? {
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
    package static let sonovoEditorPreferencesChanged = Notification.Name(
        "sonovo.editorPreferencesChanged"
    )
}
