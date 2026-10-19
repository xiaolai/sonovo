import AppKit
import SwiftUI

/// The single source of every visual value in Sonovo.
///
/// View files reference these tokens; they do not carry numeric design
/// literals. `dev-docs/DESIGN-TOKENS.md` is the ledger, and
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

        static let inspectorMinWidth: CGFloat = 264
        static let inspectorWidth: CGFloat = 304
        static let inspectorMaxWidth: CGFloat = 380

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
        static let breadcrumbHeight: CGFloat = 28
        static let transportHeight: CGFloat = 46
        static let toolbarControlHeight: CGFloat = 24
        static let toolbarContentHeight: CGFloat = 28
        static let toolbarTitleHeight: CGFloat = 30

        static let pageMaxWidth: CGFloat = 760
        static let scriptPageMaxWidth: CGFloat = 720
        static let mediaMaxWidth: CGFloat = 900
        static let dialogueMaxWidth: CGFloat = 440
        static let urlBarMaxWidth: CGFloat = 420
        static let emptyDescriptionMaxWidth: CGFloat = 300

        static let settingsWidth: CGFloat = 720
        static let settingsHeight: CGFloat = 500
        static let settingsSidebarWidth: CGFloat = 184
        static let settingsContentMaxWidth: CGFloat = 440
        static let settingsDescriptionMaxWidth: CGFloat = 300
        static let settingsRowLabelWidth: CGFloat = 150
        static let settingsPickerWidth: CGFloat = 190
        static let settingsPickerNarrowWidth: CGFloat = 170
        static let settingsPickerTinyWidth: CGFloat = 130
        static let settingsPickerCompactWidth: CGFloat = 120
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
        static let s9: CGFloat = 9
        static let s10: CGFloat = 10
        static let md: CGFloat = 12
        static let s14: CGFloat = 14
        static let lg: CGFloat = 16
        static let s18: CGFloat = 18
        static let s20: CGFloat = 20
        static let xl: CGFloat = 24
        static let s26: CGFloat = 26
        static let s28: CGFloat = 28
        static let s30: CGFloat = 30
        static let xxl: CGFloat = 32
        static let s36: CGFloat = 36
        static let s40: CGFloat = 40
        static let s42: CGFloat = 42
        static let s48: CGFloat = 48
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
        static let titleLarge: CGFloat = 18
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
        static let wider: CGFloat = 0.9
        static let widest: CGFloat = 1.0
        static let display: CGFloat = 1.2
        static let displayWide: CGFloat = 1.3
        static let displayWider: CGFloat = 1.4
        static let hero: CGFloat = 3.0
    }

    enum LineSpacing {
        static let tight: CGFloat = 3
        static let normal: CGFloat = 4
        static let relaxed: CGFloat = 5
    }

    enum Time {
        static let zero: Double = 0
    }

    enum Preferences {
        static let unitRange: ClosedRange<Double> = 0...1
        static let editorFontSizeRange: ClosedRange<Double> = 11...18
        static let editorFontSizeStep: Double = 1
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
        static let dotLarge: CGFloat = 7
        static let micro: CGFloat = 8
        static let tiny: CGFloat = 9
        static let small: CGFloat = 10
        static let footnote: CGFloat = 11
        static let regular: CGFloat = 12
        static let medium: CGFloat = 14
        static let large: CGFloat = 15
        static let row: CGFloat = 16
        static let control: CGFloat = 18
        static let extraLarge: CGFloat = 21
        static let display: CGFloat = 26
        static let empty: CGFloat = 28
        static let editorEmpty: CGFloat = 30
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
        static let rowGlyph: CGFloat = 16
        static let statusDot: CGFloat = 5
        static let statusDotLarge: CGFloat = 6
        static let avatar: CGFloat = 36
        static let inspectorTabsWidth: CGFloat = 96
        static let bottomHeaderHeight: CGFloat = 34
        static let bottomInfoColumnMinWidth: CGFloat = 170
        static let bottomNoteWidth: CGFloat = 260
        static let latestNoteWidth: CGFloat = 260
        static let takeCardWidth: CGFloat = 210
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
        static let differenceDividerHeight: CGFloat = 24
        static let timelineLineHeight: CGFloat = 42
        static let timelineDotColumnWidth: CGFloat = 8
        static let timelineDotTopPadding: CGFloat = 5
        static let letterBadge: CGFloat = 17
        static let thumbnailWidth: CGFloat = 116
        static let thumbnailHeight: CGFloat = 65
        static let stillThumbnailWidth: CGFloat = 96
        static let stillThumbnailHeight: CGFloat = 54
        static let compareHandle: CGFloat = 30
        static let compareHandleIcon: CGFloat = 8
        static let compareDividerWidth: CGFloat = 1.5
        static let compareSummaryWidth: CGFloat = 104
        static let settingsPreviewHeight: CGFloat = 92
        static let settingsSwatchWidth: CGFloat = 26
        static let settingsSwatchHeight: CGFloat = 16
        static let progressWidth: CGFloat = 180
        static let renderButtonMinWidth: CGFloat = 140
        static let terminalTabMaxWidth: CGFloat = 150
        static let tabClose: CGFloat = 20
        static let terminalTabClose: CGFloat = 20
        static let menuIcon: CGFloat = 18
        static let addIcon: CGFloat = 20
        static let inlineIcon: CGFloat = 20
        static let navigatorPickerWidth: CGFloat = 76
        static let reviewModePickerWidth: CGFloat = 94
        static let formatButtonWidth: CGFloat = 22
        static let formatButtonHeight: CGFloat = 20
        static let deliveryCardMaxWidth: CGFloat = 440
        static let miniWindowSidebar: CGFloat = 26
        static let miniWindowTrafficDot: CGFloat = 3
        static let miniWindowTitlebarHeight: CGFloat = 8
        static let miniWindowLineLong: CGFloat = 26
        static let miniWindowLineMedium: CGFloat = 22
        static let miniWindowLineShort: CGFloat = 18
        static let miniWindowLineHeight: CGFloat = 2
        static let resizeHandleWidth: CGFloat = 28
        static let resizeHandleHeight: CGFloat = 2
        static let titlebarControl: CGFloat = 22
        static let tabMaxHeight: CGFloat = 24
        static let terminalTabHeight: CGFloat = 22
        static let searchFieldHeight: CGFloat = 22
        static let noteComposerHeight: CGFloat = 28
        static let browserBarHeight: CGFloat = 38
        static let timecodePillWidth: CGFloat = 5
        static let timecodePillHeight: CGFloat = 2
        static let stillStageWidth: CGFloat = 16
        static let stillStageHeight: CGFloat = 9
        static let videoStageWidth: CGFloat = 16
        static let videoStageHeight: CGFloat = 9
        static let stageAspectWidth: CGFloat = 16
        static let stageAspectHeight: CGFloat = 9
        static let comparisonDeltaWidth: CGFloat = 104
        static let scriptPageHorizontalPadding: CGFloat = 48
        static let scriptPageVerticalPadding: CGFloat = 42
        static let scriptMaxWidth: CGFloat = 720
        static let transcriptMaxWidth: CGFloat = 760
        static let sourceLineSpacing: CGFloat = 3
        static let noValue: CGFloat = 0
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
        static let approved = Color(nsColor: .systemGreen)
        static let needsReview = Color(nsColor: .systemOrange)
        static let generating = Color(nsColor: .systemBlue)
        static let draft = Color(nsColor: .secondaryLabelColor)
        static let note = Color(nsColor: .systemOrange)
        static let white = Color.white
        static let black = Color.black
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
    static var appSecondaryLabel: Color { AppTheme.Palette.secondaryLabel }
    static var appTertiaryLabel: Color { AppTheme.Palette.tertiaryLabel }
    static var appSeparator: Color { AppTheme.Palette.separator }
    static var appSelection: Color { AppTheme.Palette.selection }
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
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.appCanvas)
        )
        .clipShape(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
        )
        .padding(inset)
    }

    func appShadow(_ token: AppTheme.ShadowToken) -> some View {
        shadow(color: token.color, radius: token.radius, x: token.x, y: token.y)
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
