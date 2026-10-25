import SonovoCore
import SwiftUI

/// Source-timeline selection surface. A click seeks, a drag selects, and a
/// drag that starts on either edge moves that edge. Removed ranges stay
/// visible but shaded, so cuts never hide where the audio came from.
struct MediaSelectionWaveformView: View {
    let data: WaveformData?
    let sourceDuration: Double
    let removedRanges: [MediaTimeRange]
    let selection: MediaTimeRange?
    let playhead: Double
    var compact = false
    var isEnabled = true
    let onSeek: (Double) -> Void
    let onSelect: (Double, Double) -> Void

    private enum DragMode {
        case newSelection
        case startHandle
        case endHandle
    }

    @State private var previewSelection: MediaTimeRange?
    @State private var dragStartX: CGFloat?
    @State private var dragMoved = false
    @State private var dragMode: DragMode = .newSelection
    @State private var dragAnchorTime: Double = 0
    @State private var fixedEdge: Double = 0

    private var visibleSelection: MediaTimeRange? {
        previewSelection ?? selection
    }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                draw(context: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(width: geometry.size.width))
            .accessibilityElement()
            .accessibilityLabel(
                compact ? "Video trim range" : "Audio selection timeline"
            )
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(
                "Click to seek. Drag to select a range; drag an edge to move it."
            )
        }
    }

    private var accessibilityValue: String {
        let source = MediaTimecodeFormatter.elapsed(sourceDuration)
        guard let selection = visibleSelection else {
            return "Source \(source), no selection"
        }
        return "Source \(source), selection "
            + "\(MediaTimecodeFormatter.elapsed(selection.start)) to "
            + "\(MediaTimecodeFormatter.elapsed(selection.end))"
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isEnabled else {
                    if dragStartX != nil { resetDrag() }
                    return
                }
                guard sourceDuration > 0, width > 0 else { return }
                let x = min(max(value.location.x, 0), width)
                let time = Double(x / width) * sourceDuration
                if dragStartX == nil {
                    beginDrag(x: x, time: time, width: width)
                }
                if let start = dragStartX,
                   abs(value.location.x - start)
                    > AppTheme.Size.mediaTrimHandleHitRadius * 0.5 {
                    dragMoved = true
                }
                updatePreview(time: time)
            }
            .onEnded { _ in
                defer { resetDrag() }
                guard isEnabled, sourceDuration > 0 else { return }
                if !dragMoved {
                    onSeek(dragAnchorTime)
                    return
                }
                guard let preview = previewSelection,
                      preview.duration
                        > MediaEditLimits.minimumSelectionDuration else {
                    return
                }
                onSelect(preview.start, preview.end)
            }
    }

    private func beginDrag(x: CGFloat, time: Double, width: CGFloat) {
        dragStartX = x
        dragAnchorTime = time
        dragMoved = false
        guard let selection,
              sourceDuration > 0 else {
            dragMode = .newSelection
            return
        }
        let startX = CGFloat(selection.start / sourceDuration) * width
        let endX = CGFloat(selection.end / sourceDuration) * width
        let tolerance = AppTheme.Size.mediaTrimHandleHitRadius
        if abs(x - startX) <= tolerance {
            dragMode = .startHandle
            fixedEdge = selection.end
            previewSelection = selection
        } else if abs(x - endX) <= tolerance {
            dragMode = .endHandle
            fixedEdge = selection.start
            previewSelection = selection
        } else {
            dragMode = .newSelection
        }
    }

    private func updatePreview(time: Double) {
        switch dragMode {
        case .newSelection:
            previewSelection = MediaTimeRange(
                start: min(dragAnchorTime, time),
                duration: abs(time - dragAnchorTime)
            )
        case .startHandle:
            previewSelection = MediaTimeRange(
                start: min(time, fixedEdge),
                duration: abs(fixedEdge - time)
            )
        case .endHandle:
            previewSelection = MediaTimeRange(
                start: min(time, fixedEdge),
                duration: abs(time - fixedEdge)
            )
        }
    }

    private func resetDrag() {
        dragStartX = nil
        dragMoved = false
        previewSelection = nil
    }

    private func draw(
        context: inout GraphicsContext,
        size: CGSize
    ) {
        let bounds = CGRect(origin: .zero, size: size)
        let radius = AppTheme.Radius.control
        context.fill(
            Path(roundedRect: bounds, cornerRadius: radius),
            with: .color(Color.appCanvas)
        )

        let middle = size.height / 2
        if let data, !data.peaks.isEmpty, size.width > 0 {
            drawWaveform(data: data, context: &context, size: size)
        } else {
            drawTrack(context: &context, size: size, middle: middle)
        }

        for range in removedRanges {
            guard let rect = rect(
                for: range,
                width: size.width,
                height: size.height
            ) else { continue }
            context.fill(
                Path(rect),
                with: .color(Color.appLabel.opacity(AppTheme.Opacity.veil))
            )
        }

        if let selection = visibleSelection,
           let rect = rect(
               for: selection,
               width: size.width,
               height: size.height
           ) {
            context.fill(
                Path(rect),
                with: .color(
                    Color.accentColor.opacity(AppTheme.Opacity.faint)
                )
            )
            let handleWidth = AppTheme.Size.mediaTrimHandleWidth
            for edge in [rect.minX, rect.maxX - handleWidth] {
                let handle = CGRect(
                    x: edge,
                    y: 0,
                    width: handleWidth,
                    height: size.height
                )
                context.fill(
                    Path(roundedRect: handle, cornerRadius: radius),
                    with: .color(Color.accentColor)
                )
            }
            let border = Path(
                roundedRect: rect,
                cornerRadius: radius
            )
            context.stroke(
                border,
                with: .color(Color.accentColor),
                lineWidth: AppTheme.BorderWidth.thin
            )
        }

        let playheadFraction = sourceDuration > 0
            ? min(max(playhead / sourceDuration, 0), 1)
            : 0
        var playheadPath = Path()
        let x = size.width * playheadFraction
        playheadPath.move(to: CGPoint(x: x, y: 0))
        playheadPath.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(
            playheadPath,
            with: .color(Color.primary.opacity(AppTheme.Opacity.strong)),
            lineWidth: AppTheme.BorderWidth.thin
        )
    }

    private func drawWaveform(
        data: WaveformData,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        guard data.duration > 0, data.peaks.count > 0 else { return }
        let middle = size.height / 2
        let columnWidth: CGFloat = 2
        let columns = max(
            NumericConversion.clamped(
                size.width / columnWidth,
                to: 0...100_000
            ),
            1
        )
        let secondsPerBucket: Double =
            data.sampleRate.isFinite
                && data.sampleRate > 0
                && data.bucketFrames > 0
            ? Double(data.bucketFrames) / data.sampleRate
            : 0
        for column in 0..<columns {
            let startTime = Double(column) / Double(columns) * data.duration
            let endTime = Double(column + 1) / Double(columns) * data.duration
            let lower: Int
            let upper: Int
            if secondsPerBucket.isFinite,
               secondsPerBucket > 0 {
                lower = min(
                    NumericConversion.floor(
                        startTime / secondsPerBucket
                    ) ?? 0,
                    data.peaks.count - 1
                )
                upper = min(
                    max(
                        NumericConversion.ceil(
                            endTime / secondsPerBucket
                        ) ?? data.peaks.count,
                        lower + 1
                    ),
                    data.peaks.count
                )
            } else {
                lower = min(
                    NumericConversion.floor(
                        Double(column) / Double(columns)
                            * Double(data.peaks.count)
                    ) ?? 0,
                    data.peaks.count - 1
                )
                upper = min(
                    max(
                        NumericConversion.floor(
                            Double(column + 1) / Double(columns)
                                * Double(data.peaks.count)
                        ) ?? data.peaks.count,
                        lower + 1
                    ),
                    data.peaks.count
                )
            }
            let peak = CGFloat(data.peaks[lower..<upper].max() ?? 0)
            let half = max(
                peak * middle * 0.92,
                AppTheme.BorderWidth.hairline
            )
            let bar = CGRect(
                x: CGFloat(column) * columnWidth,
                y: middle - half,
                width: columnWidth * 0.65,
                height: half * 2
            )
            context.fill(
                Path(bar),
                with: .color(
                    Color.secondary.opacity(AppTheme.Opacity.secondary)
                )
            )
        }
    }

    private func drawTrack(
        context: inout GraphicsContext,
        size: CGSize,
        middle: CGFloat
    ) {
        let trackHeight = AppTheme.BorderWidth.thick
        let track = CGRect(
            x: 0,
            y: middle - trackHeight / 2,
            width: size.width,
            height: trackHeight
        )
        context.fill(
            Path(roundedRect: track, cornerRadius: AppTheme.Radius.line),
            with: .color(Color.secondary.opacity(AppTheme.Opacity.muted))
        )
        let tickSpacing: CGFloat = 24
        var x = tickSpacing
        var path = Path()
        while x < size.width {
            path.move(to: CGPoint(x: x, y: middle - tickSpacing / 6))
            path.addLine(to: CGPoint(x: x, y: middle + tickSpacing / 6))
            x += tickSpacing
        }
        context.stroke(
            path,
            with: .color(Color.secondary.opacity(AppTheme.Opacity.muted)),
            lineWidth: AppTheme.BorderWidth.hairline
        )
    }

    private func rect(
        for range: MediaTimeRange,
        width: CGFloat,
        height: CGFloat
    ) -> CGRect? {
        guard sourceDuration > 0 else { return nil }
        let start = min(max(range.start / sourceDuration, 0), 1)
        let end = min(max(range.end / sourceDuration, 0), 1)
        let x = width * start
        let w = max(width * (end - start), AppTheme.BorderWidth.thin)
        let bounded = min(x + w, width)
        guard bounded > x else { return nil }
        return CGRect(x: x, y: 0, width: bounded - x, height: height)
    }
}
