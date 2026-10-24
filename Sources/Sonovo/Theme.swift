import AppKit
import SwiftUI

/// The single source of every visual value in Sonovo.
///
/// View files reference these tokens; they do not carry numeric design
/// literals. The generated ledger lives in the documentation repository, and
/// `Scripts/check-design-tokens.sh` enforces the rule.
enum AppTheme {
    // MARK: - Layout

    enum Layout {
        static let windowMinWidth: CGFloat = 1180
        static let windowMinHeight: CGFloat = 720
        static let windowDefaultWidth: CGFloat = 1440
        static let windowDefaultHeight: CGFloat = 900

        static let sidebarMinWidth: CGFloat = 224
        static let sidebarWidth: CGFloat = 264
        static let sidebarMaxWidth: CGFloat = 340

        static let inspectorWidth: CGFloat = 304

        static let terminalMinWidth: CGFloat = 340
        static let terminalMaxWidth: CGFloat = 520
        static let terminalRightFraction: CGFloat = 0.32
        static let terminalMinHeight: CGFloat = 180
        static let terminalMinEditorHeight: CGFloat = 160
        static let terminalMinFraction: CGFloat = 0.18
        static let terminalMaxFraction: CGFloat = 0.85
        static let terminalDefaultFraction: CGFloat = 0.5
        static let compareDefaultSplit: CGFloat = 0.52
        static let compareMinSplit: CGFloat = 0.08
        static let compareMaxSplit: CGFloat = 0.92
        static let transcriptPlayheadOffset: Double = 0.6
        static let autoDockThreshold: CGFloat = 1000

        static let bottomInspectorHeight: CGFloat = 240
        static let bottomInspectorMinHeight: CGFloat = 160
        static let bottomInspectorFraction: CGFloat = 0.30

        static let tabBarHeight: CGFloat = 34
        static let subtitleHeaderHeight: CGFloat = 40
        static let settingsReadingPreviewHeight: CGFloat = 320
        static let breadcrumbHeight: CGFloat = 28
        static let transportHeight: CGFloat = 46
        static let toolbarControlHeight: CGFloat = 24

        static let pageMaxWidth: CGFloat = 760
        static let markdownSidebarWidth: CGFloat = 220
        static let mediaMaxWidth: CGFloat = 900
        static let mediaVolumeMaxWidth: CGFloat = 120
        static let documentMetadataCardWidth: CGFloat = 300
        static let documentSearchFieldWidth: CGFloat = 180
        static let dialogueMaxWidth: CGFloat = 440
        static let urlBarMaxWidth: CGFloat = 420
        static let emptyDescriptionMaxWidth: CGFloat = 300

        static let sessionsMinWidth: CGFloat = 340
        static let sessionsDefaultWidth: CGFloat = 880
        static let sessionsDefaultHeight: CGFloat = 620
        static let sessionsDetailWidth: CGFloat = 280
        static let sessionsListMinWidth: CGFloat = 340
        static let sessionsNarrowListMinHeight: CGFloat = 240

        static let settingsWidth: CGFloat = 720
        static let settingsHeight: CGFloat = 500
        static let settingsSidebarWidth: CGFloat = 184
        static let settingsRowLabelWidth: CGFloat = 150
        static let settingsPickerWidth: CGFloat = 190
        static let settingsPickerNarrowWidth: CGFloat = 170
        static let settingsCustomShellWidth: CGFloat = 360
        static let settingsPickerTinyWidth: CGFloat = 130
    }

    // MARK: - Spacing

    enum Spacing {
        static let zero: CGFloat = 0
        static let hairline: CGFloat = 1
        static let xxs: CGFloat = 2
        static let s3: CGFloat = 3
        static let xs: CGFloat = 4
        static let s5: CGFloat = 5
        static let s6: CGFloat = 6
        static let s7: CGFloat = 7
        static let sm: CGFloat = 8
        static let s10: CGFloat = 10
        static let md: CGFloat = 12
        static let s14: CGFloat = 14
        static let lg: CGFloat = 16
        static let s18: CGFloat = 18
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let s40: CGFloat = 40
    }

    // MARK: - Shape

    /// One radius hierarchy: surfaces, panels, controls, micro controls.
    /// Capsules and circles are intentional exceptions.
    enum Radius {
        static let line: CGFloat = 1
        static let micro: CGFloat = 4
        static let control: CGFloat = 6
        static let panel: CGFloat = 8
        static let surface: CGFloat = 12
    }

    enum BorderWidth {
        static let hairline: CGFloat = 0.5
        static let thin: CGFloat = 1
        static let medium: CGFloat = 1.5
        static let thick: CGFloat = 2
    }

    // MARK: - Type

    /// Markdown source editor values. The editor is AppKit-backed, so these
    /// are the only place its visual numbers may live.
    enum Editor {
        static let lineFragmentPadding: CGFloat = 0
        static let visibleRangeMargin: Int = 2000
        static let minimumTextSize: CGFloat = 0
    }

    /// Code viewer and editor geometry. The code surface is read at a glance,
    /// so the gutter is narrow, the status strip is one line, and the diff
    /// gutter reserves room for a sign plus two line-number columns.
    enum Code {
        static let fontSize: CGFloat = 13
        static let lineNumberFontSize: CGFloat = 10.5
        static let statusFontSize: CGFloat = 10
        static let lineHeightMultiple: CGFloat = 1.35
        static let lineNumberWidth: CGFloat = 44
        static let lineNumberInset: CGFloat = 8
        static let contentInsetHorizontal: CGFloat = 10
        static let contentInsetVertical: CGFloat = 8
        static let statusBarHeight: CGFloat = 24
        static let toolbarHeight: CGFloat = 34
        static let diffGutterWidth: CGFloat = 22
        static let diffLineNumberWidth: CGFloat = 40
        static let searchResultRowHeight: CGFloat = 26
        static let symbolSheetWidth: CGFloat = 420
        static let symbolSheetHeight: CGFloat = 360
        static let reviewSheetWidth: CGFloat = 460
        static let reviewNoteHeight: CGFloat = 96
        static let reviewQueueHeight: CGFloat = 440
        static let goToLineFieldWidth: CGFloat = 120
        static let tabWidthDefault: Int = 4
        static let tabWidthRange: ClosedRange<Int> = 2...8

        /// Persisted tab widths are untrusted. Clamp before they reach
        /// indentation arithmetic or a repeated-string allocation.
        static func clampedTabWidth(_ value: Int) -> Int {
            min(max(value, tabWidthRange.lowerBound), tabWidthRange.upperBound)
        }
        static let indentGuideWidth: CGFloat = 1
        static let currentLineOpacity: Double = 0.055
        static let bracketOpacity: Double = 0.22
        static let diffAddedOpacity: Double = 0.16
        static let diffRemovedOpacity: Double = 0.16
        static let viewportMargin: Int = 2_000
    }

    /// Syntax roles, not colors: the code lexer names a role and the theme
    /// decides how it looks in light, dark, and high contrast.
    enum SyntaxRole: Sendable {
        case keyword
        case typeName
        case string
        case comment
        case number
        case function
        case property
        case punctuation
        case identifier
        case markup
        case inserted
        case deleted
    }

    enum Syntax {
        static func color(for role: SyntaxRole) -> NSColor {
            switch role {
            case .keyword: keyword
            case .typeName: typeName
            case .string: string
            case .comment: comment
            case .number: number
            case .function: function
            case .property: property
            case .punctuation: punctuation
            case .identifier: identifier
            case .markup: markup
            case .inserted: inserted
            case .deleted: deleted
            }
        }

        private static let keyword = dynamic(
            light: NSColor.systemPurple,
            dark: NSColor.systemPink
        )
        private static let typeName = dynamic(
            light: NSColor.systemTeal,
            dark: NSColor.systemTeal
        )
        private static let string = dynamic(
            light: NSColor.systemRed,
            dark: NSColor.systemOrange
        )
        private static let comment = NSColor.secondaryLabelColor
        private static let number = dynamic(
            light: NSColor.systemOrange,
            dark: NSColor.systemYellow
        )
        private static let function = dynamic(
            light: NSColor.systemBlue,
            dark: NSColor.systemBlue
        )
        private static let property = dynamic(
            light: NSColor.systemIndigo,
            dark: NSColor.systemIndigo
        )
        private static let punctuation = NSColor.tertiaryLabelColor
        private static let identifier = NSColor.labelColor
        private static let markup = dynamic(
            light: NSColor.systemBrown,
            dark: NSColor.systemOrange
        )
        private static let inserted = dynamic(
            light: NSColor.systemGreen,
            dark: NSColor.systemGreen
        )
        private static let deleted = dynamic(
            light: NSColor.systemRed,
            dark: NSColor.systemRed
        )

        /// High contrast swaps the quiet roles for full-strength label
        /// colors and lets the code surface keep the marks, not the tint.
        static func resolvedColor(
            for role: SyntaxRole,
            highContrast: Bool
        ) -> NSColor {
            guard highContrast else { return color(for: role) }
            switch role {
            case .comment, .punctuation: return NSColor.labelColor
            default: return color(for: role)
            }
        }

        /// Comments and punctuation are quiet; in high contrast they become
        /// bold instead of a lighter tint.
        static func isBoldInHighContrast(_ role: SyntaxRole) -> Bool {
            switch role {
            case .comment, .punctuation: return true
            default: return false
            }
        }

        private static func dynamic(
            light: NSColor,
            dark: NSColor
        ) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? dark
                    : light
            }
        }
    }

    /// Subtitle preview and cue-list geometry. Caption text is read at a
    /// glance over moving pictures, so it is sans, semibold, and larger than
    /// prose; the cue list itself uses `Reading` sizes.
    enum Model3D {
        static let conversionCardMaxWidth: CGFloat = 460
        static let logSheetWidth: CGFloat = 620
        static let logSheetHeight: CGFloat = 380
    }

    /// Project chips and the live project overview.
    enum ProjectSwitcher {
        static let chipMaxWidth: CGFloat = 148
        static let badgeSize: CGFloat = 9
        static let badgeGap: CGFloat = 3
        static let overviewWidth: CGFloat = 380
        static let overviewMaxHeight: CGFloat = 420
        static let overviewRowMinHeight: CGFloat = 52
    }

    /// Side-by-side and wipe comparison chrome.
    enum Comparison {
        static let modePickerWidth: CGFloat = 180
        static let zoomLabelWidth: CGFloat = 52
        static let dividerHitWidth: CGFloat = 24
        static let dividerHitRadius: CGFloat = 12
        static let handleDiameter: CGFloat = 22
        static let handleRadius: CGFloat = 11
        static let half: CGFloat = 0.5
        /// The narrowest side-by-side pane: keeps the stage measurable when
        /// the window is smaller than two panes plus the gap.
        static let minimumPaneWidth: CGFloat = 1
        static let metadataStripHeight: CGFloat = 68
        static let metadataDividerHeight: CGFloat = 32
        static let pickerWidth: CGFloat = 420
        static let pickerHeight: CGFloat = 420
        static let pickerRowHeight: CGFloat = 52
    }

    enum Subtitle {
        static let stageMaxWidth: CGFloat = 720
        static let stageMaxHeight: CGFloat = 360
        static let captionSize: CGFloat = 22
        static let cueTimeFieldWidth: CGFloat = 82
        static let cueIndexWidth: CGFloat = 20
        static let cueDividerInset: CGFloat = 44
        static let cueMapHeight: CGFloat = 18
        static let cueMapTrackHeight: CGFloat = 14
        static let cueMapBlockHeight: CGFloat = 4
        static let cueMapBlockCorner: CGFloat = 2
        static let cueMapPlayheadWidth: CGFloat = 2
        static let cueMapTooltipOffset: CGFloat = 20
        static let cueMapTooltipEdgeInset: CGFloat = 40
    }

    /// Typography for document text, deliberately separate from `TypeScale`.
    ///
    /// `TypeScale` sizes chrome. Reading text is larger, leads generously, and
    /// uses a narrower measure, because a document is read rather than
    /// scanned like a settings pane.
    enum Reading {
        /// Shared with subtitle cue rows. Rendered Markdown values live in
        /// the selected `MarkdownTheme`, not here.
        static let bodySize: CGFloat = 16.5
        static let bodyLineSpacing: CGFloat = 7

        // Source editor
        static let sourceSize: CGFloat = 13.5
        static let sourceLineHeightMultiple: CGFloat = 1.5
        static let sourceParagraphSpacing: CGFloat = 2
        static let sourceInsetHorizontal: CGFloat = 28
        static let sourceInsetVertical: CGFloat = 20
        static let sourceH1: CGFloat = 20
        static let sourceH2: CGFloat = 18
        static let sourceH3: CGFloat = 16
        static let sourceH4: CGFloat = 15
        static let sourceH5: CGFloat = 14
        static let sourceH6: CGFloat = 13.5

        static func sourceHeadingSize(_ level: Int) -> CGFloat {
            switch level {
            case 1: sourceH1
            case 2: sourceH2
            case 3: sourceH3
            case 4: sourceH4
            case 5: sourceH5
            default: sourceH6
            }
        }
    }

    enum TypeScale {
        static let tiny: CGFloat = 7
        static let micro: CGFloat = 8
        static let xxs: CGFloat = 9
        static let xs: CGFloat = 10
        static let caption: CGFloat = 10.5
        static let sm: CGFloat = 11
        static let body: CGFloat = 12
        static let md: CGFloat = 13
        static let lg: CGFloat = 15
        static let title: CGFloat = 16
        static let xl: CGFloat = 17
        static let hero: CGFloat = 21
        static let xxl: CGFloat = 22
        static let displaySmall: CGFloat = 24
        static let displayMedium: CGFloat = 26
        static let display: CGFloat = 28
        static let displayLarge: CGFloat = 30
    }

    enum Tracking {
        static let tight: CGFloat = 0.6
        static let normal: CGFloat = 0.7
        static let wide: CGFloat = 0.8
        static let widest: CGFloat = 1.0
        static let display: CGFloat = 1.2
        static let hero: CGFloat = 3.0
    }

    enum LineSpacing {
        static let tight: CGFloat = 3
        static let normal: CGFloat = 4
    }

    enum Time {
        static let zero: Double = 0
    }

    /// Motion shared by panes so the inspector and the sidebar feel like the
    /// same system.
    enum Motion {
        static let panelDuration: Double = 0.25
        static let panel = Animation.easeInOut(duration: panelDuration)
    }

    enum Preferences {
        static let unitRange: ClosedRange<Double> = 0...1
        static let editorFontSizeRange: ClosedRange<Double> = 11...18
        static let editorFontSizeStep: Double = 1
        static let editorFontSizeDefault: Double = 13
        static let terminalFontSizeRange: ClosedRange<Double> = 9...24
        static let terminalFontSizeStep: Double = 1
        /// Settings-preview slider defaults, as fractions of their ranges.
        static let foregroundIntensityDefault: Double = 0.48
        static let backgroundIntensityDefault: Double = 0.34
        /// How far the chosen theme accent blends toward white for chrome.
        static let accentBlendFactor: Double = 0.18
    }

    /// The editor canvas is the rounded, recessed surface inside the workspace.
    /// The inset is breathing room from the surrounding chrome and panes; the
    /// radius is shared with the cards so nested corners stay consistent.
    enum Canvas {
        static let compactInset: Double = 4
        static let comfortableInset: Double = 8
        static let spaciousInset: Double = 16

        static let squareRadius: Double = 0
        static let roundedRadius: Double = 12
        static let extraRadius: Double = 16
    }

    // MARK: - Geometry

    enum IconSize {
        static let dotSmall: CGFloat = 5
        static let dot: CGFloat = 6
        static let micro: CGFloat = 8
        static let tiny: CGFloat = 9
        static let small: CGFloat = 10
        static let regular: CGFloat = 12
        static let medium: CGFloat = 14
        static let large: CGFloat = 15
        static let row: CGFloat = 16
        static let control: CGFloat = 18
        static let extraLarge: CGFloat = 21
        static let display: CGFloat = 26
        static let empty: CGFloat = 28
        static let play: CGFloat = 52
        static let render: CGFloat = 66
    }

    enum ControlSize {
        static let mini: CGFloat = 14
        static let compact: CGFloat = 18
        static let small: CGFloat = 20
        static let regular: CGFloat = 22
        static let medium: CGFloat = 24
        static let large: CGFloat = 28
        static let extraLarge: CGFloat = 30
    }

    enum Size {
        static let toolbarDividerHeight: CGFloat = 16
        static let metadataLabelWidth: CGFloat = 76
        static let avatar: CGFloat = 36
        static let bottomHeaderHeight: CGFloat = 34
        static let bottomInfoColumnMinWidth: CGFloat = 170
        static let timecodeWidth: CGFloat = 54
        static let timecodeColumnWidth: CGFloat = 56
        static let transportTimeWidth: CGFloat = 62
        static let volumeWidth: CGFloat = 66
        static let ccWidth: CGFloat = 24
        static let ccHeight: CGFloat = 20
        static let scrubberHeight: CGFloat = 4
        static let scrubberThumb: CGFloat = 10
        static let scrubberThumbRadius: CGFloat = 5
        static let scrubberHitHeight: CGFloat = 14
        static let waveformHeight: CGFloat = 208
        static let compareWaveformHeight: CGFloat = 108
        static let letterBadge: CGFloat = 17
        static let thumbnailWidth: CGFloat = 116
        static let thumbnailHeight: CGFloat = 65
        static let stillThumbnailWidth: CGFloat = 96
        static let stillThumbnailHeight: CGFloat = 54
        /// Small row thumbnail in the asset lists.
        static let rowThumbnail: CGFloat = 32
        /// Quick Look probe request: large enough to distinguish a real
        /// document preview from an icon, and its rasterization scale.
        static let previewProbe: CGFloat = 512
        static let previewProbeScale: CGFloat = 2
        static let compareHandle: CGFloat = 30
        static let compareSummaryWidth: CGFloat = 104
        static let settingsPreviewHeight: CGFloat = 92
        static let settingsAboutIconSize: CGFloat = 72
        static let settingsSwatchWidth: CGFloat = 26
        static let settingsSwatchHeight: CGFloat = 16
        static let progressWidth: CGFloat = 180
        static let renderButtonMinWidth: CGFloat = 140
        static let terminalTabMaxWidth: CGFloat = 150
        static let sessionBadge: CGFloat = 7
        static let sessionRowMinHeight: CGFloat = 34
        static let sessionDetailLabelWidth: CGFloat = 108
        static let tabClose: CGFloat = 20
        static let terminalTabClose: CGFloat = 20
        static let menuIcon: CGFloat = 18
        static let addIcon: CGFloat = 20
        static let navigatorPickerWidth: CGFloat = 76
        static let mediaModePickerWidth: CGFloat = 94
        static let miniWindowSidebar: CGFloat = 26
        static let miniWindowTrafficDot: CGFloat = 3
        static let miniWindowTitlebarHeight: CGFloat = 8
        static let miniWindowLineLong: CGFloat = 26
        static let miniWindowLineMedium: CGFloat = 22
        static let miniWindowLineShort: CGFloat = 18
        static let miniWindowLineHeight: CGFloat = 2
        static let resizeHandleWidth: CGFloat = 28
        static let resizeHandleHeight: CGFloat = 2
        static let browserBarHeight: CGFloat = 38
        static let stageAspectWidth: CGFloat = 16
        static let stageAspectHeight: CGFloat = 9
    }

    // MARK: - Opacity

    enum Opacity {
        static let zero: Double = 0.0
        static let subtle: Double = 0.04
        static let ghost: Double = 0.05
        static let ghostSoft: Double = 0.06
        static let veil: Double = 0.07
        static let faint: Double = 0.08
        static let soft: Double = 0.10
        static let tintSoft: Double = 0.11
        static let tint: Double = 0.12
        static let muted: Double = 0.16
        static let border: Double = 0.18
        static let borderStrong: Double = 0.22
        static let medium: Double = 0.28
        static let dim: Double = 0.30
        static let secondary: Double = 0.35
        static let veilStrong: Double = 0.38
        static let wash: Double = 0.45
        static let half: Double = 0.5
        static let halfStrong: Double = 0.52
        static let strongSoft: Double = 0.55
        static let strong: Double = 0.6
        static let heavy: Double = 0.65
        static let heavySoft: Double = 0.7
        static let bright: Double = 0.8
        static let near: Double = 0.85
        static let dark: Double = 0.9
        static let opaqueSoft: Double = 0.92
        static let almost: Double = 0.95
        static let full: Double = 1.0

        static let settingsForegroundBase: Double = 0.35
        static let settingsForegroundRange: Double = 0.55
        static let settingsBackgroundBase: Double = 0.15
        static let settingsBackgroundRange: Double = 0.5
    }

    /// Resolves a SwiftUI color to concrete sRGB and blends it toward white.
    ///
    /// SwiftUI's `Color.mix` keeps a provider that AppKit resolves through
    /// `appearanceByApplyingTintColor` on every layout pass; on macOS 27 that
    /// recursion overflows the stack when the detail view changes. Resolving
    /// the tint once keeps the provider out of the view graph.
    static func blendedAccent(_ color: Color, fraction: CGFloat) -> Color {
        guard fraction > 0,
              let base = NSColor(color).usingColorSpace(.sRGB),
              let mixed = base.blended(withFraction: fraction, of: .white)
        else {
            return color
        }
        return Color(nsColor: mixed)
    }

    // MARK: - Color

    enum Palette {
        static let window = Color(nsColor: .windowBackgroundColor)
        static let content = Color(nsColor: .underPageBackgroundColor)
        /// Light keeps the recessed canvas; dark uses the pane base so the
        /// editor, tabs, and transport form one continuous surface.
        static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .textBackgroundColor
                : .underPageBackgroundColor
        })
        static let card = Color(nsColor: .controlBackgroundColor)
        static let text = Color(nsColor: .textBackgroundColor)
        static let label = Color(nsColor: .labelColor)
        static let secondaryLabel = Color(nsColor: .secondaryLabelColor)
        static let tertiaryLabel = Color(nsColor: .tertiaryLabelColor)
        static let separator = Color(nsColor: .separatorColor)
        static let selection = Color(nsColor: .selectedContentBackgroundColor)
        static let success = Color(nsColor: .systemGreen)
        static let warning = Color(nsColor: .systemOrange)
        static let info = Color(nsColor: .systemBlue)
        static let white = Color.white
        static let black = Color.black
        /// Cue-map track colors. A fixed categorical set, not an adaptive
        /// surface: hue distinguishes tracks, and the map is drawn on the
        /// panel or the video overlay rather than used for text.
        static let cueTracks: [Color] = [.blue, .teal, .indigo, .purple, .pink, .orange, .green]
        /// Settings theme bases. The default palette follows the system
        /// accent color; these two are fixed hues.
        static let slateAccent = Color(red: 0.36, green: 0.48, blue: 0.62)
        static let emberAccent = Color(red: 0.82, green: 0.46, blue: 0.22)
        // Keep these in sync with the Ghostty theme files. They match
        // NSColor.textBackgroundColor, the main editor surface.
        static let terminalLight = Color.white
        static let terminalDark = Color(red: 30.0 / 255.0, green: 30.0 / 255.0, blue: 30.0 / 255.0)

        enum MiniWindow {
            static let lightBackground = Color(red: 0.96, green: 0.96, blue: 0.97)
            static let darkBackground = Color(red: 0.11, green: 0.11, blue: 0.12)
            static let lightSidebar = Color(red: 0.91, green: 0.91, blue: 0.92)
            static let darkSidebar = Color(red: 0.15, green: 0.15, blue: 0.16)
            static let lightContent = Color.white
            static let darkContent = Color(red: 0.08, green: 0.08, blue: 0.09)
            static let trafficRed = Color(red: 0.93, green: 0.42, blue: 0.38)
            static let trafficYellow = Color(red: 0.96, green: 0.73, blue: 0.30)
            static let trafficGreen = Color(red: 0.36, green: 0.78, blue: 0.39)
        }
    }

    enum Surface {
        static let chrome: Material = .bar
        static let floating: Material = .regularMaterial
        static let mediaOverlay: Material = .ultraThinMaterial
        static let sidebar: NSVisualEffectView.Material = .sidebar
    }

    /// AppKit-only colors for layers that are not SwiftUI views.
    enum AppKitColor {
        /// Video and embedded-page canvases letterbox to black in both
        /// appearances; the content supplies every visible pixel.
        static let mediaCanvas = NSColor.black
    }

    // MARK: - Shadow

    struct ShadowToken {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    enum Shadow {
        static let card = ShadowToken(
            color: Palette.black.opacity(Opacity.faint),
            radius: 16,
            x: 0,
            y: 6
        )
        static let media = ShadowToken(
            color: Palette.black.opacity(Opacity.tint),
            radius: 12,
            x: 0,
            y: 6
        )
        static let floating = ShadowToken(
            color: Palette.black.opacity(Opacity.tint),
            radius: 8,
            x: 0,
            y: 3
        )
        static let playhead = ShadowToken(
            color: Palette.black.opacity(Opacity.muted),
            radius: 1,
            x: 0,
            y: 0.5
        )
        static let caption = ShadowToken(
            color: Palette.black.opacity(Opacity.dim),
            radius: 4,
            x: 0,
            y: 1
        )
    }
}

// MARK: - Semantic color aliases

extension Color {
    static var appWindow: Color { AppTheme.Palette.window }
    static var appContent: Color { AppTheme.Palette.content }
    static var appCanvas: Color { AppTheme.Palette.canvas }
    static var appCard: Color { AppTheme.Palette.card }
    static var appText: Color { AppTheme.Palette.text }
    static var appLabel: Color { AppTheme.Palette.label }
    static var appTertiaryLabel: Color { AppTheme.Palette.tertiaryLabel }
    static var appSeparator: Color { AppTheme.Palette.separator }

    /// Diff signs and row tints. The sign and the accessibility label still
    /// carry the meaning; color is never the only channel.
    static var appSyntaxInserted: Color {
        Color(nsColor: AppTheme.Syntax.color(for: .inserted))
    }

    static var appSyntaxDeleted: Color {
        Color(nsColor: AppTheme.Syntax.color(for: .deleted))
    }
}

// MARK: - Shared view helpers

extension View {
    func appCardStyle() -> some View {
        background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.surface, style: .continuous)
                .fill(Color.appCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.surface, style: .continuous)
                .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    /// The central editor canvas. The workspace base is the pane color; this
    /// rounded surface carries the slightly recessed editor background.
    /// Padding is applied outside the shape so the gutter is the pane color.
    func appCanvasStyle(
        inset: CGFloat = CGFloat(AppTheme.Canvas.comfortableInset),
        radius: CGFloat = CGFloat(AppTheme.Canvas.roundedRadius)
    ) -> some View {
        modifier(CanvasSurfaceStyle(inset: inset, radius: radius))
    }

    func appShadow(_ token: AppTheme.ShadowToken) -> some View {
        shadow(color: token.color, radius: token.radius, x: token.x, y: token.y)
    }
}

/// The workspace palette selected in Settings. The accent tints standard
/// controls; the wash colors the editor canvas. Intensity controls how far
/// the canvas moves from the base surface.
struct WorkspaceTheme: Equatable, Sendable {
    var accent: Color
    var wash: Color
    var backgroundIntensity: Double

    /// The default palette used outside the window's environment.
    static let standard = WorkspaceTheme(
        accent: Color.accentColor,
        wash: Color.clear,
        backgroundIntensity: 0
    )
}

private struct WorkspaceThemeKey: EnvironmentKey {
    static let defaultValue = WorkspaceTheme.standard
}

extension EnvironmentValues {
    var workspaceTheme: WorkspaceTheme {
        get { self[WorkspaceThemeKey.self] }
        set { self[WorkspaceThemeKey.self] = newValue }
    }
}

private struct CanvasSurfaceStyle: ViewModifier {
    let inset: CGFloat
    let radius: CGFloat

    @Environment(\.workspaceTheme) private var theme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.appCanvas)
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: radius,
                            style: .continuous
                        )
                        .fill(
                            theme.wash.opacity(
                                0.015 + theme.backgroundIntensity * 0.06
                            )
                        )
                    )
            )
            .clipShape(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .padding(inset)
    }
}

/// The system sidebar material, used by both the leading navigator and the
/// trailing inspector so the two panes share one background.
struct SidebarMaterialBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = AppTheme.Surface.sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
