import Foundation

package enum PreferenceKey {
    package static let restoreTabs = "sonovo.restoreTabs"
    package static let reopenLast = "sonovo.reopenLast"
    package static let editorFontSize = "sonovo.editorFontSize"
    package static let showBreadcrumbs = "sonovo.showBreadcrumbs"
    package static let wrapLines = "sonovo.wrapLines"
    package static let markdownFocusMode = "sonovo.markdownFocusMode"
    package static let markdownTypewriter = "sonovo.markdownTypewriter"
    package static let markdownLineNumbers = "sonovo.markdownLineNumbers"
    package static let audioDevice = "sonovo.audioDevice"
    package static let followPlayhead = "sonovo.followPlayhead"
    package static let captionsDefault = "sonovo.captionsDefault"
    package static let shell = "sonovo.shell"
    package static let terminalFont = "sonovo.terminalFont"
    package static let loginShell = "sonovo.loginShell"
    package static let theme = "sonovo.theme"
    package static let foregroundIntensity = "sonovo.foregroundIntensity"
    package static let backgroundIntensity = "sonovo.backgroundIntensity"
    package static let readingTheme = "sonovo.readingTheme"
    package static let readingBodySize = "sonovo.readingBodySize"
    package static let readingMeasure = "sonovo.readingMeasure"
    /// Bumped by Settings after user theme files change, so open documents
    /// rebuild their resolved theme instead of serving a cached one.
    package static let readingThemeRevision = "sonovo.readingThemeRevision"
}
