import SonovoCore
import SwiftUI

struct WaveformView: View {
    let duration: Double
    let segments: [TranscriptSegment]
    let selectedID: String?
    let playhead: Double

    private var selectedSegment: TranscriptSegment? {
        segments.first { $0.id == selectedID }
    }

    var body: some View {
        Canvas { context, size in
            guard duration > 0, size.width > 1, size.height > 1 else { return }

            let rulerHeight: CGFloat = 15
            let topPadding: CGFloat = 6
            let waveHeight = size.height - rulerHeight - topPadding
            let midY = topPadding + waveHeight / 2

            drawSelection(context: &context, size: size, topPadding: topPadding, waveHeight: waveHeight)
            drawGrid(context: &context, size: size, topPadding: topPadding, waveHeight: waveHeight, midY: midY)
            drawBars(context: &context, size: size, waveHeight: waveHeight, midY: midY)
            drawPlayhead(context: &context, size: size, topPadding: topPadding, waveHeight: waveHeight)
            drawLabels(context: &context, size: size, rulerHeight: rulerHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio waveform")
        .accessibilityValue("\(TranscriptSegment.timecode(for: duration)) long, \(segments.count) transcript segments")
    }

    private func x(for time: Double, width: CGFloat) -> CGFloat {
        CGFloat(min(max(time / duration, 0), 1)) * width
    }

    private func drawSelection(
        context: inout GraphicsContext,
        size: CGSize,
        topPadding: CGFloat,
        waveHeight: CGFloat
    ) {
        guard let segment = selectedSegment else { return }
        let startX = x(for: segment.start, width: size.width)
        let endX = x(for: segment.end, width: size.width)
        let rect = CGRect(
            x: startX,
            y: topPadding,
            width: max(endX - startX, 2),
            height: waveHeight
        )
        context.fill(
            Path(roundedRect: rect, cornerRadius: AppTheme.Radius.control),
            with: .color(Color.accentColor.opacity(AppTheme.Opacity.soft))
        )

        let bracket = Path { path in
            path.move(to: CGPoint(x: startX, y: topPadding))
            path.addLine(to: CGPoint(x: endX, y: topPadding))
        }
        context.stroke(bracket, with: .color(Color.accentColor.opacity(AppTheme.Opacity.strongSoft)), lineWidth: 1.5)
    }

    private func drawGrid(
        context: inout GraphicsContext,
        size: CGSize,
        topPadding: CGFloat,
        waveHeight: CGFloat,
        midY: CGFloat
    ) {
        let gridColor = Color.appSeparator.opacity(AppTheme.Opacity.medium)

        var centerLine = Path()
        centerLine.move(to: CGPoint(x: 0, y: midY))
        centerLine.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(centerLine, with: .color(gridColor), lineWidth: 0.5)

        var seconds = 0.0
        while seconds <= duration {
            let lineX = x(for: seconds, width: size.width)
            var line = Path()
            line.move(to: CGPoint(x: lineX, y: topPadding))
            line.addLine(to: CGPoint(x: lineX, y: topPadding + waveHeight))
            context.stroke(
                line,
                with: .color(Color.appSeparator.opacity(seconds == AppTheme.Time.zero ? AppTheme.Opacity.wash : AppTheme.Opacity.border)),
                lineWidth: 0.5
            )
            seconds += 2
        }
    }

    private func drawBars(
        context: inout GraphicsContext,
        size: CGSize,
        waveHeight: CGFloat,
        midY: CGFloat
    ) {
        let step: CGFloat = 3
        let barWidth: CGFloat = 1.6
        let barCount = max(
            1,
            NumericConversion.clamped(size.width / step, to: 0...100_000)
        )
        var bars = Path()

        for index in 0..<barCount {
            let fraction = Double(index) / Double(barCount)
            let time = fraction * duration
            let amplitude = amplitude(at: time)
            let barHeight = max(1.2, CGFloat(amplitude) * waveHeight * 0.46)
            let barX = CGFloat(index) * step + (step - barWidth) / 2
            let rect = CGRect(
                x: barX,
                y: midY - barHeight / 2,
                width: barWidth,
                height: barHeight
            )
            bars.addRoundedRect(in: rect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
        }

        context.fill(
            bars,
            with: .linearGradient(
                Gradient(colors: [
                    Color.accentColor.opacity(AppTheme.Opacity.opaqueSoft),
                    Color.accentColor.opacity(AppTheme.Opacity.strongSoft)
                ]),
                startPoint: CGPoint(x: 0, y: midY),
                endPoint: CGPoint(x: size.width, y: midY)
            )
        )
    }

    private func drawPlayhead(
        context: inout GraphicsContext,
        size: CGSize,
        topPadding: CGFloat,
        waveHeight: CGFloat
    ) {
        let playheadX = x(for: playhead, width: size.width)
        var line = Path()
        line.move(to: CGPoint(x: playheadX, y: topPadding))
        line.addLine(to: CGPoint(x: playheadX, y: topPadding + waveHeight))
        context.stroke(line, with: .color(Color.accentColor), lineWidth: 1.5)

        let dotRect = CGRect(x: playheadX - 3.5, y: topPadding - 3, width: 7, height: 7)
        context.fill(Path(ellipseIn: dotRect), with: .color(Color.accentColor))
    }

    private func drawLabels(
        context: inout GraphicsContext,
        size: CGSize,
        rulerHeight: CGFloat
    ) {
        var seconds = 0.0
        while seconds <= duration {
            let labelX = x(for: seconds, width: size.width)
            let label = Text(TranscriptSegment.timecode(for: seconds).prefix(5))
                .font(.system(size: AppTheme.TypeScale.xxs, design: .monospaced))
                .foregroundStyle(Color.secondary)
            context.draw(
                label,
                at: CGPoint(x: min(max(labelX, 16), size.width - 16), y: size.height - rulerHeight / 2),
                anchor: .center
            )
            seconds += 2
        }
    }

    private func amplitude(at time: Double) -> Double {
        guard let segment = segments.first(where: { time >= $0.start && time <= $0.end }) else {
            return 0.035
        }

        let attack = min(1, (time - segment.start) / 0.08 + 0.35)
        let release = min(1, (segment.end - time) / 0.16 + 0.18)
        let edge = min(attack, release)

        let phrase = 0.52 + 0.48 * abs(sin(time * 1.13 + 0.4) * sin(time * 0.37 + 1.2))
        let syllable = 0.58 + 0.42 * abs(sin(time * 13.7 + sin(time * 2.3)))
        let jitter = 0.88 + 0.12 * sin(time * 53.0)
        return min(1, max(0.06, 0.16 + 0.74 * phrase * syllable * jitter * edge))
    }
}
