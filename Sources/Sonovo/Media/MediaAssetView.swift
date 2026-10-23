import AppKit
import SonovoCore
import SwiftUI

/// One real audio or video file. The asset view owns its player so switching
/// tabs releases the decoder; the project watcher changes the view identity
/// when the file is overwritten.
@MainActor
struct MediaAssetView: View {
    let asset: ProjectAsset

    @State private var playback = MediaPlaybackModel()
    @State private var waveform = WaveformModel()
    @State private var scrubValue: Double?
    @Environment(\.projectIsVisible) private var projectIsVisible

    private var failure: String? {
        switch playback.state {
        case .unsupported(let message), .failed(let message):
            message
        default:
            nil
        }
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            header
            Divider()
            stage
            if failure == nil {
                Divider()
                transport
            }
        }
        .background(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.surface,
                style: .continuous
            )
            .fill(Color.appText)
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.surface,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.surface,
                style: .continuous
            )
            .strokeBorder(
                Color.appSeparator,
                lineWidth: AppTheme.BorderWidth.hairline
            )
        )
        .padding(AppTheme.Spacing.lg)
        .task(id: asset.id) {
            playback.load(url: asset.url)
        }
        .onChange(of: playback.hasAudio) { _, hasAudio in
            // The stage shows the audio layout only when metadata found no
            // video track. Key the waveform to those measured tracks, not
            // to the file extension: an audio-only MP4 classified as video
            // otherwise reaches the audio stage with an empty waveform.
            guard hasAudio, !playback.hasVideo else { return }
            waveform.load(url: asset.url, revision: asset.revision)
        }
        .onChange(of: projectIsVisible) { _, visible in
            // The project or the editor was hidden. Stop the transport but
            // keep the item and position; returning stays paused.
            if !visible {
                playback.pause()
            }
        }
        .onDisappear {
            playback.unload()
            waveform.cancel()
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: asset.kind.icon)
                .font(.system(size: AppTheme.TypeScale.body))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(asset.name)
                    .font(.system(size: AppTheme.TypeScale.md, weight: .semibold))
                    .lineLimit(1)
                Text(metadataLine)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            Text(asset.fileExtension.uppercased())
                .font(.system(size: AppTheme.TypeScale.xxs, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: AppTheme.Layout.subtitleHeaderHeight)
    }

    private var metadataLine: String {
        var parts: [String] = []
        if let codec = playback.videoCodec { parts.append(codec) }
        if playback.hasVideo, playback.videoSize.width > 0 {
            let width = NumericConversion.int(playback.videoSize.width) ?? 0
            let height = NumericConversion.int(playback.videoSize.height) ?? 0
            parts.append("\(width)×\(height)")
        }
        if playback.nominalFrameRate > 0 {
            parts.append(
                String(format: "%.2f fps", playback.nominalFrameRate)
            )
        }
        if let audio = playback.audioSummary { parts.append(audio) }
        if parts.isEmpty {
            parts.append(asset.kind.projectGroup.title)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var stage: some View {
        if let failure {
            failureState(failure)
        } else if playback.state == .ready {
            if playback.hasVideo {
                MediaPlayerView(player: playback.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.Palette.black)
            } else {
                audioStage
            }
        } else {
            loadingState
        }
    }

    private var audioStage: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            if case .failed(let message) = waveform.state {
                Text(message)
                    .font(.system(size: AppTheme.TypeScale.sm))
                    .foregroundStyle(.secondary)
            }
            MediaWaveformView(
                data: waveform.data,
                progress: playback.duration > 0
                    ? playback.elapsed / playback.duration
                    : 0
            ) { fraction in
                Task { @MainActor in
                    await playback.seek(
                        to: fraction * playback.duration
                    )
                }
            }
            .frame(height: AppTheme.Size.waveformHeight)

            if waveform.state == .loading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            ProgressView()
            Text("Loading media…")
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(
                    .system(
                        size: AppTheme.TypeScale.displayLarge,
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(AppTheme.Palette.warning)
            Text("Could not play this file")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))
            Text(message)
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: AppTheme.Layout.emptyDescriptionMaxWidth)
            Text(asset.url.path)
                .font(.system(size: AppTheme.TypeScale.xs, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Open in Default App") {
                NSWorkspace.shared.open(asset.url)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transport: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                BarIconButton(
                    systemName: playback.isPlaying ? "pause.fill" : "play.fill",
                    help: playback.isPlaying ? "Pause" : "Play"
                ) {
                    playback.togglePlayback()
                }
                .disabled(playback.state != .ready)

                BarIconButton(systemName: "gobackward.5", help: "Back 5 seconds") {
                    playback.skip(by: -5)
                }
                .disabled(playback.state != .ready)

                BarIconButton(systemName: "goforward.5", help: "Forward 5 seconds") {
                    playback.skip(by: 5)
                }
                .disabled(playback.state != .ready)

                if playback.hasVideo {
                    BarIconButton(
                        systemName: "backward.frame",
                        help: playback.isFrameRateVerified
                            ? "Previous frame"
                            : "Frame stepping needs verified constant timing"
                    ) {
                        playback.stepFrames(-1)
                    }
                    .disabled(
                        playback.state != .ready
                            || !playback.isFrameRateVerified
                    )

                    BarIconButton(
                        systemName: "forward.frame",
                        help: playback.isFrameRateVerified
                            ? "Next frame"
                            : "Frame stepping needs verified constant timing"
                    ) {
                        playback.stepFrames(1)
                    }
                    .disabled(
                        playback.state != .ready
                            || !playback.isFrameRateVerified
                    )
                }

                Text(positionLabel)
                    .font(.system(size: AppTheme.TypeScale.xs, design: .monospaced))
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { scrubValue ?? playback.elapsed },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(playback.duration, 0.001),
                    onEditingChanged: { editing in
                        guard !editing, let value = scrubValue else { return }
                        scrubValue = nil
                        Task { @MainActor in
                            await playback.seek(to: value)
                        }
                    }
                )
                .disabled(playback.state != .ready)

                Text(MediaTimecodeFormatter.elapsed(playback.duration))
                    .font(.system(size: AppTheme.TypeScale.xs, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(playback.volume) },
                        set: { playback.volume = Float($0) }
                    ),
                    in: 0...1
                )
                .frame(maxWidth: AppTheme.Layout.mediaVolumeMaxWidth)

                if playback.hasVideo {
                    Toggle("Loop", isOn: Binding(
                        get: { playback.isLooping },
                        set: { playback.isLooping = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: AppTheme.TypeScale.xs))
                }

                Spacer()

                if let source = playback.timecode.sourceLabel {
                    Text("TC \(source)")
                        .font(.system(size: AppTheme.TypeScale.xxs, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    private var positionLabel: String {
        playback.timecode.sourceLabel
            ?? MediaTimecodeFormatter.elapsed(playback.elapsed)
    }
}
