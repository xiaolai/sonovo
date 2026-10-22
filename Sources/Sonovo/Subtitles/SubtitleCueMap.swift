import SonovoCore
import SwiftUI

enum SubtitleCueMapStyle {
    case panel
    case overlay

    var palette: [Color] {
        AppTheme.Palette.cueTracks
    }

    func color(forOrdinal ordinal: Int) -> Color {
        let color = palette[abs(ordinal) % palette.count]
        switch self {
        case .panel:
            return color.opacity(AppTheme.Opacity.strongSoft)
        case .overlay:
            return color.opacity(AppTheme.Opacity.bright)
        }
    }

    var active: Color {
        switch self {
        case .panel: Color.accentColor
        case .overlay: AppTheme.Palette.white
        }
    }

    var selected: Color {
        switch self {
        case .panel:
            Color.accentColor.opacity(AppTheme.Opacity.strongSoft)
        case .overlay:
            AppTheme.Palette.white.opacity(AppTheme.Opacity.heavySoft)
        }
    }

    var hovered: Color {
        switch self {
        case .panel:
            Color.accentColor.opacity(AppTheme.Opacity.medium)
        case .overlay:
            AppTheme.Palette.white.opacity(AppTheme.Opacity.half)
        }
    }

    var playhead: Color {
        switch self {
        case .panel: Color.accentColor
        case .overlay: AppTheme.Palette.white
        }
    }

    var upcoming: Color {
        switch self {
        case .panel:
            Color.secondary.opacity(AppTheme.Opacity.dim)
        case .overlay:
            AppTheme.Palette.white.opacity(AppTheme.Opacity.border)
        }
    }

    var labelBackground: Color {
        switch self {
        case .panel: Color.appText
        case .overlay:
            AppTheme.Palette.black.opacity(AppTheme.Opacity.heavySoft)
        }
    }

    var labelForeground: Color {
        switch self {
        case .panel: Color.primary
        case .overlay: AppTheme.Palette.white
        }
    }
}

/// The cue strip in the floating player: every cue as a proportional block, a
/// live playhead, hover feedback, and drag-to-seek.
struct SubtitleCueMap: View {
    let cues: [SubtitleCue]
    let durationMilliseconds: Int
    let currentMilliseconds: Int
    let activeOrdinals: Set<Int>
    let selectedOrdinal: Int?
    var style: SubtitleCueMapStyle = .panel
    var tooltipBelow = false
    let onSeek: (Int) -> Void

    @State private var hoverX: CGFloat?
    @State private var hoverTime: Int?
    @State private var hoveredOrdinal: Int?

    private var total: Int {
        max(durationMilliseconds, 1)
    }

    private var progress: CGFloat {
        min(
            max(CGFloat(currentMilliseconds) / CGFloat(total), 0),
            1
        )
    }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                draw(
                    context: &context,
                    size: size,
                    width: max(geometry.size.width, AppTheme.Spacing.hairline)
                )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onSeek(time(at: value.location.x, width: geometry.size.width))
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    updateHover(
                        at: location.x,
                        width: geometry.size.width
                    )
                case .ended:
                    clearHover()
                }
            }
            .overlay {
                if let hoverX, let hoverTime {
                    hoverLabel(time: hoverTime)
                        .fixedSize()
                        .position(
                            x: min(
                                max(
                                    hoverX,
                                    AppTheme.Subtitle.cueMapTooltipEdgeInset
                                ),
                                max(
                                    geometry.size.width
                                        - AppTheme.Subtitle.cueMapTooltipEdgeInset,
                                    AppTheme.Subtitle.cueMapTooltipEdgeInset
                                )
                            ),
                            y: tooltipBelow
                                ? geometry.size.height
                                    + AppTheme.Subtitle.cueMapTooltipOffset
                                : -AppTheme.Subtitle.cueMapTooltipOffset
                        )
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: AppTheme.Subtitle.cueMapHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cue map")
        .accessibilityValue("\(cues.count) cues")
        .accessibilityHint("Click or drag to seek")
    }

    private func draw(
        context: inout GraphicsContext,
        size: CGSize,
        width: CGFloat
    ) {
        let trackHeight = AppTheme.Subtitle.cueMapTrackHeight
        let trackY = (size.height - trackHeight) / 2
        // No track fill: the colored cue blocks are the timeline. A filled
        // strip behind them reads as a background and a border.

        let blockHeight = AppTheme.Subtitle.cueMapBlockHeight
        let blockY = (size.height - blockHeight) / 2
        for cue in cues {
            guard cue.durationMilliseconds > 0 else { continue }
            let start = CGFloat(cue.startMilliseconds) / CGFloat(total)
            let blockWidth = max(
                CGFloat(cue.durationMilliseconds) / CGFloat(total) * width,
                AppTheme.Spacing.xxs
            )
            let x = min(
                max(start * width, 0),
                max(width - blockWidth, 0)
            )
            let rect = CGRect(
                x: x,
                y: blockY,
                width: min(blockWidth, width - x),
                height: blockHeight
            )
            let color: Color
            if activeOrdinals.contains(cue.ordinal) {
                color = style.active
            } else if hoveredOrdinal == cue.ordinal {
                color = style.hovered
            } else if cue.startMilliseconds > currentMilliseconds {
                color = style.upcoming
            } else if selectedOrdinal == cue.ordinal {
                color = style.selected
            } else {
                color = style.color(forOrdinal: cue.ordinal)
            }
            context.fill(
                Path(
                    roundedRect: rect,
                    cornerRadius: AppTheme.Subtitle.cueMapBlockCorner
                ),
                with: .color(color)
            )
        }

        let x = progress * width
        var line = Path()
        line.move(
            to: CGPoint(x: x, y: trackY - AppTheme.Spacing.xxs)
        )
        line.addLine(
            to: CGPoint(
                x: x,
                y: trackY + trackHeight + AppTheme.Spacing.xxs
            )
        )
        context.stroke(
            line,
            with: .color(style.playhead),
            lineWidth: AppTheme.Subtitle.cueMapPlayheadWidth
        )
    }

    private func hoverLabel(time: Int) -> some View {
        let text: String
        if let hoveredOrdinal,
           let cue = cues.first(where: { $0.ordinal == hoveredOrdinal }) {
            text = "Cue \(cue.ordinal + 1) · "
                + SubtitleTimecode.displayShort(cue.startMilliseconds)
        } else {
            text = SubtitleTimecode.displayShort(time)
        }
        return Text(text)
            .font(
                .system(
                    size: AppTheme.TypeScale.xxs,
                    weight: .medium,
                    design: .monospaced
                )
            )
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(Capsule().fill(style.labelBackground))
            .foregroundStyle(style.labelForeground)
    }

    private func updateHover(at x: CGFloat, width: CGFloat) {
        let milliseconds = time(at: x, width: width)
        hoverX = x
        hoverTime = milliseconds
        hoveredOrdinal = cues.first {
            $0.startMilliseconds <= milliseconds
                && milliseconds < $0.endMilliseconds
        }?.ordinal
    }

    private func clearHover() {
        hoverX = nil
        hoverTime = nil
        hoveredOrdinal = nil
    }

    private func time(at x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        let fraction = min(max(x / width, 0), 1)
        return Int(fraction * CGFloat(total))
    }
}
