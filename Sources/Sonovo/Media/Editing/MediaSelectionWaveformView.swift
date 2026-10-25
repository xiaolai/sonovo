import SonovoCore
import SwiftUI

enum MediaSelectionEdge: Sendable {
    case start
    case end
}

/// Source-timeline selection surface. A click seeks, a drag selects, and a
/// drag that starts on either edge moves that edge. Removed ranges stay
/// visible but shaded, so cuts never hide where the audio came from.
struct MediaSelectionWaveformView: View {
    let data: WaveformData?
    let sourceDuration: Double
    let removedRanges: [MediaTimeRange]
    let selection: MediaTimeRange?
    let playhead: Double
    let viewport: MediaTimelineViewport
    var silenceCandidates: [MediaTimeRange] = []
    var compact = false
    var isInteractionEnabled = true
    let onSeek: (Double) -> Void
    let onSelect: (Double, Double) -> Void
    var onNudge: ((MediaSelectionEdge, Double) -> Void)?
    var onInteractionChange: ((Bool) -> Void)?

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
    @State private var dragViewport: MediaTimelineViewport?
    @State private var activeEdge: MediaSelectionEdge?
    @FocusState private var isFocused: Bool

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
            .focusable()
            .focused($isFocused)
            .onKeyPress(
                keys: [.leftArrow, .rightArrow],
                phases: .down
            ) { press in
                guard isInteractionEnabled,
                      let edge = activeEdge ?? (selection == nil ? nil : .end),
                      let onNudge else {
                    return .ignored
                }
                let step = press.modifiers.contains(.shift)
                    ? MediaEditLimits.selectionNudgeCoarseStep
                    : MediaEditLimits.selectionNudgeStep
                let direction: Double = press.key == .leftArrow ? -1 : 1
                onNudge(edge, step * direction)
                return .handled
            }
            .overlay {
                if isFocused {
                    RoundedRectangle(
                        cornerRadius: AppTheme.Radius.control,
                        style: .continuous
                    )
                    .strokeBorder(
                        Color.accentColor.opacity(AppTheme.Opacity.secondary),
                        lineWidth: AppTheme.BorderWidth.thin
                    )
                }
            }
            .accessibilityElement()
            .accessibilityLabel(
                compact ? "Video trim range" : "Audio selection timeline"
            )
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(
                "Click to seek. Drag to select a range; drag an edge to move it. Arrow keys nudge the active edge."
            )
            .accessibilityAdjustableAction { direction in
                guard isInteractionEnabled,
                      let edge = activeEdge ?? (selection == nil ? nil : .end),
                      let onNudge else {
                    return
                }
                let step: Double
                switch direction {
                case .increment: step = MediaEditLimits.selectionNudgeStep
                case .decrement: step = -MediaEditLimits.selectionNudgeStep
                @unknown default: return
                }
                onNudge(edge, step)
            }
        }
    }

    private var accessibilityValue: String {
        let source = MediaTimecodeFormatter.elapsed(sourceDuration)
        let visible = "\(MediaTimecodeFormatter.elapsed(viewport.start)) to \(MediaTimecodeFormatter.elapsed(viewport.end))"
        guard let selection = visibleSelection else {
            return "Source \(source), visible \(visible), no selection"
        }
        return "Source \(source), visible \(visible), selection "
            + "\(MediaTimecodeFormatter.elapsed(selection.start)) to "
            + "\(MediaTimecodeFormatter.elapsed(selection.end))"
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isInteractionEnabled else {
                    if dragStartX != nil { resetDrag() }
                    return
                }
                guard sourceDuration > 0, width > 0 else { return }
                let x = min(max(value.location.x, 0), width)
                let activeViewport = dragViewport ?? viewport
                let time = activeViewport.time(
                    atFraction: Double(x / width)
                )
                if dragStartX == nil {
                    dragViewport = viewport
                    isFocused = true
                    onInteractionChange?(true)
                    beginDrag(
                        x: x,
                        time: time,
                        width: width,
                        viewport: activeViewport
                    )
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
                guard isInteractionEnabled, sourceDuration > 0 else {
                    return
                }
                if !dragMoved {
                    onSeek(dragAnchorTime)
                    return
                }
                guard let preview = previewSelection,
                      preview.duration
                        > MediaEditLimits.minimumSelectionDuration else {
                    return
                }
                if activeEdge == nil {
                    activeEdge = .end
                }
                onSelect(preview.start, preview.end)
            }
    }

    private func beginDrag(
        x: CGFloat,
        time: Double,
        width: CGFloat,
        viewport: MediaTimelineViewport
    ) {
        dragStartX = x
        dragAnchorTime = time
        dragMoved = false
        guard let selection,
              sourceDuration > 0 else {
            dragMode = .newSelection
            activeEdge = nil
            return
        }
        let startX = CGFloat(viewport.fraction(forTime: selection.start))
            * width
        let endX = CGFloat(viewport.fraction(forTime: selection.end)) * width
        let tolerance = AppTheme.Size.mediaTrimHandleHitRadius
        if abs(x - startX) <= tolerance {
            dragMode = .startHandle
            activeEdge = .start
            fixedEdge = selection.end
            previewSelection = selection
        } else if abs(x - endX) <= tolerance {
            dragMode = .endHandle
            activeEdge = .end
            fixedEdge = selection.start
            previewSelection = selection
        } else {
            dragMode = .newSelection
            activeEdge = nil
        }
    }

    private func updatePreview(time: Double) {
        switch dragMode {
        case .newSelection:
            previewSelection = MediaTimeRange(
                start: min(dragAnchorTime, time),
                duration: abs(time - dragAnchorTime)
            )
        case .startHandle, .endHandle:
            // Dragging one handle across the other swaps the bounds. Track
            // the bound under the pointer so a following arrow-key nudge
            // moves the edge the user just dragged, not the one left behind.
            activeEdge = time < fixedEdge ? .start : .end
            previewSelection = MediaTimeRange(
                start: min(time, fixedEdge),
                duration: abs(time - fixedEdge)
            )
        }
    }

    private func resetDrag() {
        let wasDragging = dragStartX != nil
        dragStartX = nil
        dragMoved = false
        dragViewport = nil
        previewSelection = nil
        if wasDragging {
            onInteractionChange?(false)
        }
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
            drawWaveform(
                data: data,
                context: &context,
                size: size,
                viewport: viewport
            )
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

        for range in silenceCandidates {
            guard let rect = rect(
                for: range,
                width: size.width,
                height: size.height
            ) else { continue }
            context.fill(
                Path(rect),
                with: .color(
                    AppTheme.Palette.warning.opacity(AppTheme.Opacity.tintSoft)
                )
            )
            var marker = Path()
            marker.move(to: CGPoint(x: rect.minX, y: 0))
            marker.addLine(to: CGPoint(x: rect.maxX, y: 0))
            context.stroke(
                marker,
                with: .color(AppTheme.Palette.warning),
                lineWidth: AppTheme.BorderWidth.thick
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
            if x(for: selection.start, width: size.width) != nil {
                drawHandle(
                    context: &context,
                    x: rect.minX,
                    width: handleWidth,
                    height: size.height,
                    isActive: activeEdge == .start
                )
            }
            if x(for: selection.end, width: size.width) != nil {
                drawHandle(
                    context: &context,
                    x: rect.maxX - handleWidth,
                    width: handleWidth,
                    height: size.height,
                    isActive: activeEdge == .end
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

        if let x = x(for: playhead, width: size.width) {
            var playheadPath = Path()
            playheadPath.move(to: CGPoint(x: x, y: 0))
            playheadPath.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(
                playheadPath,
                with: .color(
                    Color.primary.opacity(AppTheme.Opacity.strong)
                ),
                lineWidth: AppTheme.BorderWidth.thin
            )
        }
    }

    private func drawHandle(
        context: inout GraphicsContext,
        x: CGFloat,
        width: CGFloat,
        height: CGFloat,
        isActive: Bool
    ) {
        let handle = CGRect(x: x, y: 0, width: width, height: height)
        context.fill(
            Path(
                roundedRect: handle,
                cornerRadius: AppTheme.Radius.control
            ),
            with: .color(
                isActive
                    ? AppTheme.Palette.warning
                    : Color.accentColor
            )
        )
    }

    private func drawWaveform(
        data: WaveformData,
        context: inout GraphicsContext,
        size: CGSize,
        viewport: MediaTimelineViewport
    ) {
        guard data.duration > 0,
              data.peaks.count > 0,
              data.sampleRate > 0,
              data.bucketFrames > 0,
              viewport.duration > 0 else {
            return
        }
        let middle = size.height / 2
        let columnWidth: CGFloat = 2
        let columns = max(
            NumericConversion.clamped(
                size.width / columnWidth,
                to: 0...100_000
            ),
            1
        )
        let secondsPerBucket = Double(data.bucketFrames) / data.sampleRate
        guard secondsPerBucket > 0 else { return }
        let dataEnd = Double(data.peaks.count * data.bucketFrames)
            / data.sampleRate

        for column in 0..<columns {
            let startTime = viewport.time(
                atFraction: Double(column) / Double(columns)
            )
            let endTime = viewport.time(
                atFraction: Double(column + 1) / Double(columns)
            )
            guard startTime < dataEnd else { continue }
            let lower = max(
                min(
                    Int((startTime / secondsPerBucket).rounded(.down)),
                    data.peaks.count - 1
                ),
                0
            )
            let upper = max(
                min(
                    Int((endTime / secondsPerBucket).rounded(.up)),
                    data.peaks.count
                ),
                lower + 1
            )
            var peak: Float = 0
            var hasAudio = false
            for bucket in lower..<upper {
                guard bucket < data.bucketFrameCounts.count,
                      data.bucketFrameCounts[bucket] > 0 else {
                    continue
                }
                hasAudio = true
                peak = max(peak, data.peaks[bucket])
            }
            guard hasAudio else { continue }
            let half = max(
                CGFloat(peak) * middle * 0.92,
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

    private func x(for time: Double, width: CGFloat) -> CGFloat? {
        guard viewport.duration > 0, width > 0,
              time >= viewport.start,
              time <= viewport.end else {
            return nil
        }
        return width * CGFloat(viewport.fraction(forTime: time))
    }

    private func rect(
        for range: MediaTimeRange,
        width: CGFloat,
        height: CGFloat
    ) -> CGRect? {
        guard viewport.duration > 0, width > 0 else { return nil }
        let visibleStart = max(range.start, viewport.start)
        let visibleEnd = min(range.end, viewport.end)
        guard visibleEnd > visibleStart else { return nil }
        let x = width * CGFloat(viewport.fraction(forTime: visibleStart))
        let xEnd = width * CGFloat(viewport.fraction(forTime: visibleEnd))
        let w = max(xEnd - x, AppTheme.BorderWidth.thin)
        let bounded = min(x + w, width)
        guard bounded > x else { return nil }
        return CGRect(x: x, y: 0, width: bounded - x, height: height)
    }
}
