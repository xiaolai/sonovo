import AppKit
import SwiftUI

/// The single source of every visual value in Sonovo.
///
/// View files reference these tokens; they do not carry numeric design
/// literals. The generated ledger lives in the documentation repository, and
/// `Scripts/check-design-tokens.sh` enforces the rule.
package enum AppTheme {
    // MARK: - Layout

    package enum Layout {
        package static let windowMinWidth: CGFloat = 1180
        package static let windowMinHeight: CGFloat = 720
        package static let windowDefaultWidth: CGFloat = 1440
        package static let windowDefaultHeight: CGFloat = 900

        package static let sidebarMinWidth: CGFloat = 224
        package static let sidebarWidth: CGFloat = 264
        package static let sidebarMaxWidth: CGFloat = 340

        package static let inspectorWidth: CGFloat = 304

        package static let terminalMinWidth: CGFloat = 340
        package static let terminalMaxWidth: CGFloat = 520
        package static let terminalRightFraction: CGFloat = 0.32
        package static let terminalMinHeight: CGFloat = 180
        package static let terminalMinEditorHeight: CGFloat = 160
        package static let terminalMinFraction: CGFloat = 0.18
        package static let terminalMaxFraction: CGFloat = 0.85
        package static let terminalDefaultFraction: CGFloat = 0.5
        package static let compareDefaultSplit: CGFloat = 0.52
        package static let compareMinSplit: CGFloat = 0.08
        package static let compareMaxSplit: CGFloat = 0.92
        package static let transcriptPlayheadOffset: Double = 0.6
        package static let autoDockThreshold: CGFloat = 1000

        package static let bottomInspectorHeight: CGFloat = 240
        package static let bottomInspectorMinHeight: CGFloat = 160
        package static let bottomInspectorFraction: CGFloat = 0.30

        package static let tabBarHeight: CGFloat = 34
        package static let subtitleHeaderHeight: CGFloat = 40
        package static let settingsReadingPreviewHeight: CGFloat = 320
        package static let breadcrumbHeight: CGFloat = 28
        package static let transportHeight: CGFloat = 46
        package static let toolbarControlHeight: CGFloat = 24

        package static let pageMaxWidth: CGFloat = 760
        package static let markdownSidebarWidth: CGFloat = 220
        package static let mdxSourceMinWidth: CGFloat = 280
        package static let mdxPreviewMinWidth: CGFloat = 320
        package static let mediaMaxWidth: CGFloat = 900
        package static let mediaVolumeMaxWidth: CGFloat = 120
        package static let documentMetadataCardWidth: CGFloat = 300
        package static let documentSearchFieldWidth: CGFloat = 180
        package static let dialogueMaxWidth: CGFloat = 440
        package static let urlBarMaxWidth: CGFloat = 420
        package static let emptyDescriptionMaxWidth: CGFloat = 300

        package static let sessionsMinWidth: CGFloat = 340
        package static let sessionsDefaultWidth: CGFloat = 880
        package static let sessionsDefaultHeight: CGFloat = 620
        package static let sessionsDetailWidth: CGFloat = 280
        package static let sessionsListMinWidth: CGFloat = 340
        package static let sessionsNarrowListMinHeight: CGFloat = 240

        package static let settingsWidth: CGFloat = 720
        package static let settingsHeight: CGFloat = 500
        package static let settingsSidebarWidth: CGFloat = 184
        package static let settingsRowLabelWidth: CGFloat = 150
        package static let settingsPickerWidth: CGFloat = 190
        package static let settingsPickerNarrowWidth: CGFloat = 170
        package static let settingsCustomShellWidth: CGFloat = 360
        package static let settingsPickerTinyWidth: CGFloat = 130
    }

    // MARK: - Spacing

    package enum Spacing {
        package static let zero: CGFloat = 0
        package static let hairline: CGFloat = 1
        package static let xxs: CGFloat = 2
        package static let s3: CGFloat = 3
        package static let xs: CGFloat = 4
        package static let s5: CGFloat = 5
        package static let s6: CGFloat = 6
        package static let s7: CGFloat = 7
        package static let sm: CGFloat = 8
        package static let s10: CGFloat = 10
        package static let md: CGFloat = 12
        package static let s14: CGFloat = 14
        package static let lg: CGFloat = 16
        package static let s18: CGFloat = 18
        package static let xl: CGFloat = 24
        package static let xxl: CGFloat = 32
        package static let s40: CGFloat = 40
    }

    // MARK: - Shape

    /// One radius hierarchy: surfaces, panels, controls, micro controls.
    /// Capsules and circles are intentional exceptions.
    package enum Radius {
        package static let line: CGFloat = 1
        package static let micro: CGFloat = 4
        package static let control: CGFloat = 6
        package static let panel: CGFloat = 8
        package static let surface: CGFloat = 12
    }

    package enum BorderWidth {
        package static let hairline: CGFloat = 0.5
        package static let thin: CGFloat = 1
        package static let medium: CGFloat = 1.5
        package static let thick: CGFloat = 2
    }

    // MARK: - Type

    /// Markdown source editor values. The editor is AppKit-backed, so these
    /// are the only place its visual numbers may live.
    package enum Editor {
        package static let lineFragmentPadding: CGFloat = 0
        package static let visibleRangeMargin: Int = 2000
        package static let minimumTextSize: CGFloat = 0
    }

    /// Multi-cursor chrome. The native primary caret is untouched; these
    /// values govern the secondary carets and the selection tint only.
    package enum MultiCursor {
        package static let caretWidth: CGFloat = 2
        package static let selectionAlpha: CGFloat = 0.28
        package static var caretColor: NSColor { .controlAccentColor }
        package static var selectionColor: NSColor {
            NSColor.controlAccentColor
                .withAlphaComponent(selectionAlpha)
        }
    }

    /// Code viewer and editor geometry. The code surface is read at a glance,
    /// so the gutter is narrow, the status strip is one line, and the diff
    /// gutter reserves room for a sign plus two line-number columns.
    package enum Code {
        package static let fontSize: CGFloat = 13
        package static let lineNumberFontSize: CGFloat = 10.5
        package static let statusFontSize: CGFloat = 10
        package static let lineHeightMultiple: CGFloat = 1.35
        package static let lineNumberWidth: CGFloat = 44
        package static let lineNumberInset: CGFloat = 8
        package static let contentInsetHorizontal: CGFloat = 10
        package static let contentInsetVertical: CGFloat = 8
        package static let statusBarHeight: CGFloat = 24
        package static let toolbarHeight: CGFloat = 34
        package static let diffGutterWidth: CGFloat = 22
        package static let diffLineNumberWidth: CGFloat = 40
        package static let searchResultRowHeight: CGFloat = 26
        package static let symbolSheetWidth: CGFloat = 420
        package static let symbolSheetHeight: CGFloat = 360
        package static let reviewSheetWidth: CGFloat = 460
        package static let reviewNoteHeight: CGFloat = 96
        package static let reviewQueueHeight: CGFloat = 440
        package static let goToLineFieldWidth: CGFloat = 120
        /// The problems list above a workflow chart stops growing here and
        /// scrolls instead.
        package static let workflowDiagnosticsMaxHeight: CGFloat = 144
        package static let tabWidthDefault: Int = 4
        package static let tabWidthRange: ClosedRange<Int> = 2...8

        /// Persisted tab widths are untrusted. Clamp before they reach
        /// indentation arithmetic or a repeated-string allocation.
        package static func clampedTabWidth(_ value: Int) -> Int {
            min(max(value, tabWidthRange.lowerBound), tabWidthRange.upperBound)
        }
        package static let indentGuideWidth: CGFloat = 1
        package static let currentLineOpacity: Double = 0.055
        package static let bracketOpacity: Double = 0.22
        package static let diffAddedOpacity: Double = 0.16
        package static let diffRemovedOpacity: Double = 0.16
        package static let viewportMargin: Int = 2_000
    }

    /// Syntax roles, not colors: the code lexer names a role and the theme
    /// decides how it looks in light, dark, and high contrast.
    package enum SyntaxRole: Sendable {
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

    package enum Syntax {
        package static func color(for role: SyntaxRole) -> NSColor {
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
        package static func resolvedColor(
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
        package static func isBoldInHighContrast(_ role: SyntaxRole) -> Bool {
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
    package enum Model3D {
        package static let conversionCardMaxWidth: CGFloat = 460
        package static let logSheetWidth: CGFloat = 620
        package static let logSheetHeight: CGFloat = 380
    }

    /// Project chips and the live project overview.
    package enum ProjectSwitcher {
        package static let chipMaxWidth: CGFloat = 148
        package static let badgeSize: CGFloat = 9
        package static let badgeGap: CGFloat = 3
        package static let overviewWidth: CGFloat = 380
        package static let overviewMaxHeight: CGFloat = 420
        package static let overviewRowMinHeight: CGFloat = 52
    }

    /// Shared zoom behavior for image viewers.
    package enum Viewer {
        package static let minimumZoom: CGFloat = 0.001
        package static let maximumZoom: CGFloat = 16
        /// A tiny image fitted large can need a 1:1 zoom below the normal
        /// floor; this keeps the actual-size calculation finite.
        package static let actualSizeFloor: CGFloat = 0.0001
        package static let zoomFloorFactor: CGFloat = 0.5
        package static let zoomCeilingFactor: CGFloat = 1.5
        package static let doubleTapToleranceFloor: CGFloat = 0.001
        package static let doubleTapToleranceFraction: CGFloat = 0.01
    }

    /// Side-by-side and wipe comparison chrome.
    package enum Comparison {
        package static let minimumWipeFraction: Double = 0.02
        package static let maximumWipeFraction: Double = 0.98
        package static let defaultWipeFraction: Double = 0.5
        package static let modePickerWidth: CGFloat = 180
        package static let zoomLabelWidth: CGFloat = 52
        package static let dividerHitWidth: CGFloat = 24
        package static let dividerHitRadius: CGFloat = 12
        package static let handleDiameter: CGFloat = 22
        package static let handleRadius: CGFloat = 11
        package static let half: CGFloat = 0.5
        /// The narrowest side-by-side pane: keeps the stage measurable when
        /// the window is smaller than two panes plus the gap.
        package static let minimumPaneWidth: CGFloat = 1
        package static let metadataStripHeight: CGFloat = 68
        package static let metadataDividerHeight: CGFloat = 32
        package static let pickerWidth: CGFloat = 420
        package static let pickerHeight: CGFloat = 420
        package static let pickerRowHeight: CGFloat = 52
    }

    package enum Subtitle {
        package static let stageMaxWidth: CGFloat = 720
        package static let stageMaxHeight: CGFloat = 360
        package static let captionSize: CGFloat = 22
        package static let cueTimeFieldWidth: CGFloat = 82
        package static let cueIndexWidth: CGFloat = 20
        package static let cueDividerInset: CGFloat = 44
        package static let cueMapHeight: CGFloat = 18
        package static let cueMapTrackHeight: CGFloat = 14
        package static let cueMapBlockHeight: CGFloat = 4
        package static let cueMapBlockCorner: CGFloat = 2
        package static let cueMapPlayheadWidth: CGFloat = 2
        package static let cueMapTooltipOffset: CGFloat = 20
        package static let cueMapTooltipEdgeInset: CGFloat = 40
    }

    /// Typography for document text, deliberately separate from `TypeScale`.
    ///
    /// `TypeScale` sizes chrome. Reading text is larger, leads generously, and
    /// uses a narrower measure, because a document is read rather than
    /// scanned like a settings pane.
    package enum Reading {
        /// Shared with subtitle cue rows. Rendered Markdown values live in
        /// the selected `MarkdownTheme`, not here.
        package static let bodySize: CGFloat = 16.5
        package static let bodySizeStep: Double = 0.5
        package static let measureStep: Double = 10
        package static let bodyLineSpacing: CGFloat = 7

        // Source editor
        package static let sourceSize: CGFloat = 13.5
        package static let sourceLineHeightMultiple: CGFloat = 1.5
        package static let sourceParagraphSpacing: CGFloat = 2
        package static let sourceInsetHorizontal: CGFloat = 28
        package static let sourceInsetVertical: CGFloat = 20
        package static let sourceH1: CGFloat = 20
        package static let sourceH2: CGFloat = 18
        package static let sourceH3: CGFloat = 16
        package static let sourceH4: CGFloat = 15
        package static let sourceH5: CGFloat = 14
        package static let sourceH6: CGFloat = 13.5

        // Footnote references
        /// A footnote reference scales with the body text it sits in.
        package static let footnoteScale: CGFloat = 0.72
        /// How far the superscript number rises above the baseline, in points.
        package static let footnoteBaselineOffset: Double = 4.5

        package static func sourceHeadingSize(_ level: Int) -> CGFloat {
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

    package enum TypeScale {
        package static let tiny: CGFloat = 7
        package static let micro: CGFloat = 8
        package static let xxs: CGFloat = 9
        package static let xs: CGFloat = 10
        package static let caption: CGFloat = 10.5
        package static let sm: CGFloat = 11
        package static let body: CGFloat = 12
        package static let md: CGFloat = 13
        package static let lg: CGFloat = 15
        package static let title: CGFloat = 16
        package static let xl: CGFloat = 17
        package static let hero: CGFloat = 21
        package static let xxl: CGFloat = 22
        package static let displaySmall: CGFloat = 24
        package static let displayMedium: CGFloat = 26
        package static let display: CGFloat = 28
        package static let displayLarge: CGFloat = 30
    }

    package enum Tracking {
        package static let tight: CGFloat = 0.6
        package static let normal: CGFloat = 0.7
        package static let wide: CGFloat = 0.8
        package static let widest: CGFloat = 1.0
        package static let display: CGFloat = 1.2
        package static let hero: CGFloat = 3.0
    }

    package enum LineSpacing {
        package static let tight: CGFloat = 3
        package static let normal: CGFloat = 4
    }

    package enum Time {
        package static let zero: Double = 0
        /// Floor for a computed timeout, so an exhausted budget still gives
        /// the timer one scheduling opportunity.
        package static let minimumTimeout: Double = 0.1
    }

    /// Motion shared by panes so the inspector and the sidebar feel like the
    /// same system.
    package enum Motion {
        package static let panelDuration: Double = 0.25
        package static let panel = Animation.easeInOut(duration: panelDuration)
    }

    package enum Preferences {
        package static let unitRange: ClosedRange<Double> = 0...1
        package static let editorFontSizeRange: ClosedRange<Double> = 11...18
        package static let editorFontSizeStep: Double = 1
        package static let editorFontSizeDefault: Double = 13
        package static let terminalFontSizeRange: ClosedRange<Double> = 9...24
        package static let terminalFontSizeStep: Double = 1
        /// Settings-preview slider defaults, as fractions of their ranges.
        package static let foregroundIntensityDefault: Double = 0.48
        package static let backgroundIntensityDefault: Double = 0.34
        /// How far the chosen theme accent blends toward white for chrome.
        package static let accentBlendFactor: Double = 0.18
    }

    /// The editor canvas is the rounded, recessed surface inside the workspace.
    /// The inset is breathing room from the surrounding chrome and panes; the
    /// radius is shared with the cards so nested corners stay consistent.
    package enum Canvas {
        package static let compactInset: Double = 4
        package static let comfortableInset: Double = 8
        package static let spaciousInset: Double = 16

        package static let squareRadius: Double = 0
        package static let roundedRadius: Double = 12
        package static let extraRadius: Double = 16
    }

    // MARK: - Geometry

    package enum IconSize {
        package static let dotSmall: CGFloat = 5
        package static let dot: CGFloat = 6
        package static let micro: CGFloat = 8
        package static let tiny: CGFloat = 9
        package static let small: CGFloat = 10
        package static let regular: CGFloat = 12
        package static let medium: CGFloat = 14
        package static let large: CGFloat = 15
        package static let row: CGFloat = 16
        package static let control: CGFloat = 18
        package static let extraLarge: CGFloat = 21
        package static let display: CGFloat = 26
        package static let empty: CGFloat = 28
        package static let play: CGFloat = 52
        package static let render: CGFloat = 66
    }

    package enum ControlSize {
        package static let mini: CGFloat = 14
        package static let compact: CGFloat = 18
        package static let small: CGFloat = 20
        package static let regular: CGFloat = 22
        package static let medium: CGFloat = 24
        package static let large: CGFloat = 28
        package static let extraLarge: CGFloat = 30
    }

    /// Timeline interaction factors. The zoom factor is a control constant,
    /// not a drawing size, but it lives here with the other timeline values.
    package enum MediaTimeline {
        package static let zoomInFactor: Double = 2
        package static let zoomOutFactor: Double = 0.5
    }

    package enum Size {
        package static let toolbarDividerHeight: CGFloat = 16
        package static let metadataLabelWidth: CGFloat = 76
        package static let avatar: CGFloat = 36
        package static let bottomHeaderHeight: CGFloat = 34
        package static let bottomInfoColumnMinWidth: CGFloat = 170
        package static let timecodeWidth: CGFloat = 54
        package static let timecodeColumnWidth: CGFloat = 56
        package static let transportTimeWidth: CGFloat = 62
        package static let volumeWidth: CGFloat = 66
        package static let ccWidth: CGFloat = 24
        package static let ccHeight: CGFloat = 20
        package static let scrubberHeight: CGFloat = 4
        package static let scrubberThumb: CGFloat = 10
        package static let scrubberThumbRadius: CGFloat = 5
        package static let scrubberHitHeight: CGFloat = 14
        package static let waveformHeight: CGFloat = 208
        /// Compact timeline height when the window is short or the video
        /// preview needs the remaining space.
        package static let mediaTimelineCompactHeight: CGFloat = 120
        package static let mediaTimelineThumbnailHeight: CGFloat = 56
        package static let mediaTimelineThumbnailTileWidth: CGFloat = 72
        package static let mediaSilencePopoverWidth: CGFloat = 320
        package static let mediaTranscriptPaneWidth: CGFloat = 360
        /// Project timeline geometry. Pixels per second is a content zoom,
        /// not a chrome dimension, but it is shared by the ruler and clips.
        package static let timelineRulerHeight: CGFloat = 24
        package static let timelinePreviewHeight: CGFloat = 220
        package static let timelineTrackHeight: CGFloat = 72
        package static let timelineClipHeight: CGFloat = 52
        package static let timelineClipMinWidth: CGFloat = 6
        package static let timelinePixelsPerSecond: Double = 80
        package static let timelineMinimumPixelsPerSecond: Double = 20
        package static let timelineMaximumPixelsPerSecond: Double = 400
        package static let timelineMinimumSeconds: Double = 10
        package static let timelineRulerStepSeconds: Double = 1
        package static let timelineZoomFactor: Double = 1.5
        package static let timelinePercentScale: Double = 100
        package static let timelineMaximumGain: Double = 1
        package static let timelineMaximumRulerSteps: Int = 10_000
        package static let timelinePlayheadWidth: CGFloat = 1
        package static let timelineTrimHandleWidth: CGFloat = 8
        package static let letterBadge: CGFloat = 17
        package static let thumbnailWidth: CGFloat = 116
        package static let thumbnailHeight: CGFloat = 65
        package static let stillThumbnailWidth: CGFloat = 96
        package static let stillThumbnailHeight: CGFloat = 54
        /// Small row thumbnail in the asset lists.
        package static let rowThumbnail: CGFloat = 32
        /// Quick Look probe request: large enough to distinguish a real
        /// document preview from an icon, and its rasterization scale.
        package static let previewProbe: CGFloat = 512
        package static let previewProbeScale: CGFloat = 2
        package static let compareHandle: CGFloat = 30
        package static let compareSummaryWidth: CGFloat = 104
        package static let settingsPreviewHeight: CGFloat = 92
        package static let settingsAboutIconSize: CGFloat = 72
        package static let settingsSwatchWidth: CGFloat = 26
        package static let settingsSwatchHeight: CGFloat = 16
        package static let progressWidth: CGFloat = 180
        package static let renderButtonMinWidth: CGFloat = 140
        package static let terminalTabMaxWidth: CGFloat = 150
        package static let sessionBadge: CGFloat = 7
        package static let sessionRowMinHeight: CGFloat = 34
        package static let sessionDetailLabelWidth: CGFloat = 108
        package static let tabClose: CGFloat = 20
        package static let terminalTabClose: CGFloat = 20
        package static let menuIcon: CGFloat = 18
        package static let addIcon: CGFloat = 20
        package static let mediaModePickerWidth: CGFloat = 94
        package static let mediaTrimStripHeight: CGFloat = 52
        package static let mediaTrimHandleWidth: CGFloat = 3
        package static let mediaTrimHandleHitRadius: CGFloat = 10
        package static let mediaRecordLevelWidth: CGFloat = 120
        package static let mediaStatusMaxWidth: CGFloat = 440
        package static let miniWindowSidebar: CGFloat = 26
        package static let miniWindowTrafficDot: CGFloat = 3
        package static let miniWindowTitlebarHeight: CGFloat = 8
        package static let miniWindowLineLong: CGFloat = 26
        package static let miniWindowLineMedium: CGFloat = 22
        package static let miniWindowLineShort: CGFloat = 18
        package static let miniWindowLineHeight: CGFloat = 2
        package static let resizeHandleWidth: CGFloat = 28
        package static let resizeHandleHeight: CGFloat = 2
        package static let browserBarHeight: CGFloat = 38
        package static let stageAspectWidth: CGFloat = 16
        package static let stageAspectHeight: CGFloat = 9
    }

    // MARK: - Opacity

    package enum Opacity {
        package static let zero: Double = 0.0
        package static let subtle: Double = 0.04
        package static let ghost: Double = 0.05
        package static let ghostSoft: Double = 0.06
        package static let veil: Double = 0.07
        package static let faint: Double = 0.08
        package static let soft: Double = 0.10
        package static let tintSoft: Double = 0.11
        package static let tint: Double = 0.12
        package static let muted: Double = 0.16
        package static let border: Double = 0.18
        package static let borderStrong: Double = 0.22
        package static let medium: Double = 0.28
        package static let dim: Double = 0.30
        package static let secondary: Double = 0.35
        package static let veilStrong: Double = 0.38
        package static let wash: Double = 0.45
        package static let half: Double = 0.5
        package static let halfStrong: Double = 0.52
        package static let strongSoft: Double = 0.55
        package static let strong: Double = 0.6
        package static let heavy: Double = 0.65
        package static let heavySoft: Double = 0.7
        package static let bright: Double = 0.8
        package static let near: Double = 0.85
        package static let dark: Double = 0.9
        package static let opaqueSoft: Double = 0.92
        package static let almost: Double = 0.95
        package static let full: Double = 1.0

        package static let settingsForegroundBase: Double = 0.35
        package static let settingsForegroundRange: Double = 0.55
        package static let settingsBackgroundBase: Double = 0.15
        package static let settingsBackgroundRange: Double = 0.5
    }

    /// Resolves a SwiftUI color to concrete sRGB and blends it toward white.
    ///
    /// SwiftUI's `Color.mix` keeps a provider that AppKit resolves through
    /// `appearanceByApplyingTintColor` on every layout pass; on macOS 27 that
    /// recursion overflows the stack when the detail view changes. Resolving
    /// the tint once keeps the provider out of the view graph.
    package static func blendedAccent(_ color: Color, fraction: CGFloat) -> Color {
        guard fraction > 0,
              let base = NSColor(color).usingColorSpace(.sRGB),
              let mixed = base.blended(withFraction: fraction, of: .white)
        else {
            return color
        }
        return Color(nsColor: mixed)
    }

    /// The SwiftUI form of a syntax role. Kept here so a content renderer
    /// can color a token without constructing a raw color.
    package static func syntaxColor(for role: SyntaxRole) -> Color {
        Color(nsColor: Syntax.color(for: role))
    }

    // MARK: - Color

    package enum Palette {
        package static let window = Color(nsColor: .windowBackgroundColor)
        package static let content = Color(nsColor: .underPageBackgroundColor)
        /// Light keeps the recessed canvas; dark uses the pane base so the
        /// editor, tabs, and transport form one continuous surface.
        package static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .textBackgroundColor
                : .underPageBackgroundColor
        })
        package static let card = Color(nsColor: .controlBackgroundColor)
        package static let text = Color(nsColor: .textBackgroundColor)
        package static let label = Color(nsColor: .labelColor)
        package static let secondaryLabel = Color(nsColor: .secondaryLabelColor)
        package static let tertiaryLabel = Color(nsColor: .tertiaryLabelColor)
        package static let separator = Color(nsColor: .separatorColor)
        package static let selection = Color(nsColor: .selectedContentBackgroundColor)
        package static let success = Color(nsColor: .systemGreen)
        package static let warning = Color(nsColor: .systemOrange)
        package static let error = Color(nsColor: .systemRed)
        package static let info = Color(nsColor: .systemBlue)
        package static let white = Color.white
        package static let black = Color.black
        /// Cue-map track colors. A fixed categorical set, not an adaptive
        /// surface: hue distinguishes tracks, and the map is drawn on the
        /// panel or the video overlay rather than used for text.
        package static let cueTracks: [Color] = [.blue, .teal, .indigo, .purple, .pink, .orange, .green]
        /// Settings theme bases. The default palette follows the system
        /// accent color; these two are fixed hues.
        package static let slateAccent = Color(red: 0.36, green: 0.48, blue: 0.62)
        package static let emberAccent = Color(red: 0.82, green: 0.46, blue: 0.22)
        // Keep these in sync with the Ghostty theme files. They match
        // NSColor.textBackgroundColor, the main editor surface.
        package static let terminalLight = Color.white
        package static let terminalDark = Color(red: 30.0 / 255.0, green: 30.0 / 255.0, blue: 30.0 / 255.0)

        package enum MiniWindow {
            package static let lightBackground = Color(red: 0.96, green: 0.96, blue: 0.97)
            package static let darkBackground = Color(red: 0.11, green: 0.11, blue: 0.12)
            package static let lightSidebar = Color(red: 0.91, green: 0.91, blue: 0.92)
            package static let darkSidebar = Color(red: 0.15, green: 0.15, blue: 0.16)
            package static let lightContent = Color.white
            package static let darkContent = Color(red: 0.08, green: 0.08, blue: 0.09)
            package static let trafficRed = Color(red: 0.93, green: 0.42, blue: 0.38)
            package static let trafficYellow = Color(red: 0.96, green: 0.73, blue: 0.30)
            package static let trafficGreen = Color(red: 0.36, green: 0.78, blue: 0.39)
        }
    }

    package enum Surface {
        package static let chrome: Material = .bar
        package static let floating: Material = .regularMaterial
        package static let mediaOverlay: Material = .ultraThinMaterial
        package static let sidebar: NSVisualEffectView.Material = .sidebar
    }

    /// AppKit-only colors for layers that are not SwiftUI views.
    package enum AppKitColor {
        /// Video and embedded-page canvases letterbox to black in both
        /// appearances; the content supplies every visible pixel.
        package static let mediaCanvas = NSColor.black
    }

    // MARK: - Shadow

    package struct ShadowToken {

        package init(
            color: Color,
            radius: CGFloat,
            x: CGFloat,
            y: CGFloat
        ) {
            self.color = color
            self.radius = radius
            self.x = x
            self.y = y
        }

        package let color: Color
        package let radius: CGFloat
        package let x: CGFloat
        package let y: CGFloat
    }

    package enum Shadow {
        package static let card = ShadowToken(
            color: Palette.black.opacity(Opacity.faint),
            radius: 16,
            x: 0,
            y: 6
        )
        package static let media = ShadowToken(
            color: Palette.black.opacity(Opacity.tint),
            radius: 12,
            x: 0,
            y: 6
        )
        package static let floating = ShadowToken(
            color: Palette.black.opacity(Opacity.tint),
            radius: 8,
            x: 0,
            y: 3
        )
        package static let playhead = ShadowToken(
            color: Palette.black.opacity(Opacity.muted),
            radius: 1,
            x: 0,
            y: 0.5
        )
        package static let caption = ShadowToken(
            color: Palette.black.opacity(Opacity.dim),
            radius: 4,
            x: 0,
            y: 1
        )
    }

    /// Tokens for the Markdown surfaces added by the authoring roadmap.
    /// Content renderers still draw content; these are chrome values.
    package enum MarkdownChrome {
        package enum CodeHeader {
            package static let height: CGFloat = 28
            package static let inset = Spacing.sm
            package static let background = Palette.content
            package static let feedback = Palette.success
            package static let copyFeedbackSeconds: Double = 1.5
        }

        package enum Alerts {
            package static let note = Palette.info
            package static let tip = Palette.success
            package static let important = Palette.info
            package static let warning = Palette.warning
            package static let caution = Palette.error
            package static let borderWidth = BorderWidth.thick
            package static let inset = Spacing.md
        }

        package enum Frontmatter {
            package static let height: CGFloat = 140
        }

        package enum Popover {
            package static let width: CGFloat = 320
            package static let padding = Spacing.md
            package static let background = Palette.card
            /// Side of the point-sized anchor rect for a zero-width range.
            package static let anchorSize: CGFloat = 1
        }

        package enum Lint {
            package static let error = Palette.error
            package static let warning = Palette.warning
            package static let tint = Opacity.muted
            package static let markerWidth = BorderWidth.medium
        }

        package enum TableCell {
            package static let highlight = Palette.selection
            package static let opacity = Opacity.muted
        }

        package enum Outline {
            package static let selection = Palette.selection
            package static let inset = Spacing.sm
            package static let rowHeight: CGFloat = 22
            package static let width: CGFloat = 220
        }

        package enum PaletteChrome {
            package static let width: CGFloat = 520
            package static let height: CGFloat = 420
            package static let background = Palette.card
            package static let padding = Spacing.md
        }

        package enum Review {
            package static let unreviewed = Palette.info
            package static let seen = Palette.success
            package static let changesRequested = Palette.warning
            package static let stale = Palette.tertiaryLabel
        }

        /// Source Peek and semantic block editing: the projection editor.
        package enum BlockEditor {
            package static let minHeight: CGFloat = 88
            package static let maxHeight: CGFloat = 280
            package static let popoverWidth: CGFloat = 480
            package static let padding = Spacing.sm
            package static let background = Palette.text
            package static let border = Palette.separator
        }

        /// The inline table grid: a popover over the table's source range.
        package enum TableGrid {
            package static let width: CGFloat = 560
            package static let height: CGFloat = 440
            package static let cellWidth: CGFloat = 150
            package static let cellMinHeight: CGFloat = 24
            package static let headerBackground = Palette.card
            package static let backdrop = Palette.text
        }

        /// Agent proposal diffs: the sheet that previews hunks before an
        /// undoable, compare-and-swap source edit.
        package enum Proposal {
            package static let width: CGFloat = 680
            package static let height: CGFloat = 560
            package static let lineNumberWidth: CGFloat = 44
            package static let added = Palette.success
            package static let removed = Palette.error
            package static let tint = Opacity.tintSoft
        }

        /// Focus mode dims source blocks outside the current one. The
        /// decoration owns only the foreground key; syntax stays underneath.
        package enum Focus {
            package static let dim = Palette.tertiaryLabel
        }

        /// Typewriter mode keeps the caret line near 40% of the viewport.
        package enum Typewriter {
            package static let centerFraction: CGFloat = 0.4
            package static let jitter: CGFloat = 12
        }

        /// Review comments: the source margin that marks anchored threads
        /// and the trailing panel that lists them.
        package enum Comments {
            package static let gutterWidth: CGFloat = 14
            package static let markerDiameter: CGFloat = 7
            package static let markerHitRadius: CGFloat = 9
            package static let markerCenterDivisor: CGFloat = 2
            package static let open = Palette.info
            package static let resolved = Palette.tertiaryLabel
            package static let unresolved = Palette.warning
            package static let panelWidth: CGFloat = 300
            package static let panelMinHeight: CGFloat = 240
            package static let quoteLineLimit: Int = 2
            package static let bodyLineLimit: Int = 6
            package static let selectionTint = Opacity.tint
        }

        package enum ReadingPosition {
            package static let indicator = Palette.tertiaryLabel
            package static let opacity = Opacity.borderStrong
            package static let width = BorderWidth.medium
        }

        /// HTML and PDF export. The exported page uses the reading theme's
        /// own typography and colors; these values are only the fixed parts
        /// the theme does not carry, such as A4 pagination.
        package enum Export {
            /// A4 in PostScript points, the PDF page the print operation
            /// produces.
            package static let paperWidth: CGFloat = 595.28
            package static let paperHeight: CGFloat = 841.89
            /// 18 mm of print margin on every edge.
            package static let printMargin: CGFloat = 51.02
            /// The printable area the offscreen web view is laid out in.
            package static var printableWidth: CGFloat {
                paperWidth - printMargin * 2
            }
            package static var printableHeight: CGFloat {
                paperHeight - printMargin * 2
            }
            /// CSS has no theme value for heading leading; the viewer's
            /// default line height is close to 1.2.
            package static let headingLineHeight: Double = 1.2
            /// The inline code pill, which the viewer draws as a colored
            /// text run with no padding.
            package static let inlineCodeHorizontalPadding = Spacing.xs
            package static let inlineCodeVerticalPadding = Spacing.xxs
            /// A sub-point difference between a measured block boundary and
            /// the page limit is rounding, not a real boundary.
            package static let geometryEpsilon: CGFloat = 0.5
        }

        /// Math typesetting. Formulas are vector Core Graphics layouts; the
        /// export rasterizes them at this multiple so print output stays
        /// sharp.
        package enum Math {
            package static let exportScale: CGFloat = 3
        }
    }
}

// MARK: - Semantic color aliases

extension Color {
    package static var appWindow: Color { AppTheme.Palette.window }
    package static var appContent: Color { AppTheme.Palette.content }
    package static var appCanvas: Color { AppTheme.Palette.canvas }
    package static var appCard: Color { AppTheme.Palette.card }
    package static var appText: Color { AppTheme.Palette.text }
    package static var appLabel: Color { AppTheme.Palette.label }
    package static var appTertiaryLabel: Color { AppTheme.Palette.tertiaryLabel }
    package static var appSeparator: Color { AppTheme.Palette.separator }

    /// Diff signs and row tints. The sign and the accessibility label still
    /// carry the meaning; color is never the only channel.
    package static var appSyntaxInserted: Color {
        Color(nsColor: AppTheme.Syntax.color(for: .inserted))
    }

    package static var appSyntaxDeleted: Color {
        Color(nsColor: AppTheme.Syntax.color(for: .deleted))
    }
}

// MARK: - Shared view helpers

extension View {
    package func appCardStyle() -> some View {
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
    package func appCanvasStyle(
        inset: CGFloat = CGFloat(AppTheme.Canvas.comfortableInset),
        radius: CGFloat = CGFloat(AppTheme.Canvas.roundedRadius)
    ) -> some View {
        modifier(CanvasSurfaceStyle(inset: inset, radius: radius))
    }

    package func appShadow(_ token: AppTheme.ShadowToken) -> some View {
        shadow(color: token.color, radius: token.radius, x: token.x, y: token.y)
    }
}

/// The workspace palette selected in Settings. The accent tints standard
/// controls; the wash colors the editor canvas. Intensity controls how far
/// the canvas moves from the base surface.
package struct WorkspaceTheme: Equatable, Sendable {

    package init(
        accent: Color,
        wash: Color,
        backgroundIntensity: Double
    ) {
        self.accent = accent
        self.wash = wash
        self.backgroundIntensity = backgroundIntensity
    }

    package var accent: Color
    package var wash: Color
    package var backgroundIntensity: Double

    /// The default palette used outside the window's environment.
    package static let standard = WorkspaceTheme(
        accent: Color.accentColor,
        wash: Color.clear,
        backgroundIntensity: 0
    )
}

private struct WorkspaceThemeKey: EnvironmentKey {
    static let defaultValue = WorkspaceTheme.standard
}

extension EnvironmentValues {
    package var workspaceTheme: WorkspaceTheme {
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
package struct SidebarMaterialBackground: NSViewRepresentable {
    package init(material: NSVisualEffectView.Material = AppTheme.Surface.sidebar) {
        self.material = material
    }

    package var material: NSVisualEffectView.Material = AppTheme.Surface.sidebar

    package func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.isEmphasized = false
        return view
    }

    package func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
