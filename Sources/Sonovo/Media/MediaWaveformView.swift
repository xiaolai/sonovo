import SwiftUI

struct MediaWaveformView: View {
    let data: WaveformData?
    let progress: Double
    var onSeek: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard let data, !data.peaks.isEmpty, size.width > 0 else {
                    return
                }
                let middle = size.height / 2
                let columnWidth: CGFloat = 2
                let columns = max(Int(size.width / columnWidth), 1)
                let played = min(max(progress, 0), 1)
                // Buckets are fixed frame counts, not equal fractions of
                // the duration. Map each column through time so a short
                // final bucket starts where its audio starts.
                let secondsPerBucket = data.sampleRate > 0
                    ? Double(data.bucketFrames) / data.sampleRate
                    : 0
                let duration = max(data.duration, 0)

                for column in 0..<columns {
                    let lower: Int
                    let upper: Int
                    if secondsPerBucket > 0, duration > 0 {
                        let startTime = Double(column) / Double(columns)
                            * duration
                        let endTime = Double(column + 1) / Double(columns)
                            * duration
                        lower = min(
                            Int(startTime / secondsPerBucket),
                            data.peaks.count - 1
                        )
                        upper = min(
                            max(
                                Int(ceil(endTime / secondsPerBucket)),
                                lower + 1
                            ),
                            data.peaks.count
                        )
                    } else {
                        lower = min(
                            Int(
                                Double(column) / Double(columns)
                                    * Double(data.peaks.count)
                            ),
                            data.peaks.count - 1
                        )
                        upper = min(
                            max(
                                Int(
                                    Double(column + 1) / Double(columns)
                                        * Double(data.peaks.count)
                                ),
                                lower + 1
                            ),
                            data.peaks.count
                        )
                    }
                    let peak = CGFloat(
                        data.peaks[lower..<upper].max() ?? 0
                    )
                    let half = max(
                        peak * middle * 0.92,
                        AppTheme.BorderWidth.hairline
                    )
                    let x = CGFloat(column) * columnWidth
                    let fraction = Double(column) / Double(columns)
                    let color = fraction <= played
                        ? Color.accentColor
                        : Color.secondary.opacity(AppTheme.Opacity.muted)
                    let bar = CGRect(
                        x: x,
                        y: middle - half,
                        width: columnWidth * 0.65,
                        height: half * 2
                    )
                    context.fill(Path(bar), with: .color(color))
                }

                let playheadX = size.width * played
                var path = Path()
                path.move(to: CGPoint(x: playheadX, y: 0))
                path.addLine(to: CGPoint(x: playheadX, y: size.height))
                context.stroke(
                    path,
                    with: .color(Color.primary.opacity(AppTheme.Opacity.muted)),
                    lineWidth: AppTheme.BorderWidth.hairline
                )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let onSeek else { return }
                        let width = max(geometry.size.width, 1)
                        let fraction = min(
                            max(value.location.x / width, 0),
                            1
                        )
                        onSeek(fraction)
                    }
            )
            .accessibilityLabel("Waveform")
        }
    }
}
