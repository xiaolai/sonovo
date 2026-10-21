import SwiftUI

struct TransportBar: View {
    @Bindable var state: AppState

    private var isMediaTab: Bool {
        guard let kind = state.selectedTab?.kind else { return false }
        return kind == .audio || kind == .video
    }

    var body: some View {
        Group {
            if state.terminalPresentation == .full {
                terminalBar
            } else if isMediaTab {
                mediaTransport
            } else {
                contextBar
            }
        }
        .frame(height: AppTheme.Layout.transportHeight)
        .background(Color.appText)
    }

    private var terminalBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "terminal")
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)

            Text("Terminal")
                .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))

            Text(
                (
                    (state.terminalSessions.selectedSession?.workingDirectory
                        ?? "~") as NSString
                ).abbreviatingWithTildeInPath
            )
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: AppTheme.Spacing.sm)

            Text("⌃`")
                .font(.system(size: AppTheme.TypeScale.xs, design: .monospaced))
                .foregroundStyle(.tertiary)

            BarIconButton(
                systemName: "rectangle.split.2x1",
                help: "Restore editor"
            ) {
                state.terminalPresentation = .split
            }

            BarIconButton(systemName: "xmark", help: "Hide terminal") {
                state.terminalPresentation = .hidden
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
    }

    private var mediaTransport: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.xxs) {
                BarIconButton(
                    systemName: state.isPlaying ? "pause.fill" : "play.fill",
                    help: state.isPlaying ? "Pause" : "Play"
                ) {
                    state.togglePlayback()
                }

                BarIconButton(systemName: "gobackward.5", help: "Back 5 seconds") {
                    state.playhead = max(0, state.playhead - 5)
                }

                BarIconButton(systemName: "goforward.5", help: "Forward 5 seconds") {
                    state.playhead = min(state.duration, state.playhead + 5)
                }
            }

            HStack(spacing: AppTheme.Spacing.s3) {
                Text(TranscriptSegment.timecode(for: state.playhead))
                    .font(.system(size: AppTheme.TypeScale.sm, weight: .medium, design: .monospaced))
                    .frame(width: AppTheme.Size.transportTimeWidth, alignment: .leading)
                Text("/")
                    .foregroundStyle(.tertiary)
                Text(TranscriptSegment.timecode(for: state.duration))
                    .font(.system(size: AppTheme.TypeScale.sm, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: AppTheme.Size.transportTimeWidth, alignment: .leading)
            }
            .monospacedDigit()

            Scrubber(state: state)
                .frame(maxWidth: .infinity)

            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: AppTheme.TypeScale.sm))
                    .foregroundStyle(.secondary)

                Slider(value: $state.volume, in: AppTheme.Preferences.unitRange)
                    .controlSize(.mini)
                    .frame(width: AppTheme.Size.volumeWidth)
                    .help("Volume")
                    .accessibilityLabel("Volume")

                Button {
                    state.showCaptions.toggle()
                } label: {
                    Text("CC")
                        .font(.system(size: AppTheme.TypeScale.xxs, weight: .bold))
                        .frame(width: AppTheme.Size.ccWidth, height: AppTheme.Size.ccHeight)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.control)
                                .fill(state.showCaptions ? Color.accentColor.opacity(AppTheme.Opacity.muted) : Color.clear)
                        )
                        .foregroundStyle(state.showCaptions ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(state.showCaptions ? "Hide captions" : "Show captions")
                .accessibilityLabel(state.showCaptions ? "Hide captions" : "Show captions")

                BarIconButton(
                    systemName: "repeat",
                    help: state.isLooping ? "Turn off loop" : "Loop",
                    isSelected: state.isLooping
                ) {
                    state.isLooping.toggle()
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
    }

    private var contextBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if let tab = state.selectedTab,
               let asset = state.production.asset(id: tab.assetID) {
                Image(systemName: tab.kind.icon)
                    .font(.system(size: AppTheme.TypeScale.sm))
                    .foregroundStyle(.secondary)

                Text(state.displayName(for: asset))
                    .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
                    .lineLimit(1)

                Text(contextDetail(for: tab))
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)

                Spacer(minLength: AppTheme.Spacing.sm)

                Text(contextRight(for: tab))
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.tertiary)
            } else {
                Text("No editor open")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
    }

    private func contextDetail(for tab: EditorTab) -> String {
        if tab.kind == .script,
           let document = state.markdown.selectedDocument {
            return "\(state.markdownWordCount(document.source).formatted()) words"
        }
        if tab.kind == .subtitle,
           let document = state.subtitles.selectedDocument {
            return "\(document.cueCount) cues"
        }
        if tab.kind == .model3d,
           let document = state.models.selectedDocument {
            if let stats = document.stats {
                return "\(stats.triangles.formatted()) triangles"
            }
            return switch document.state {
            case .needsConversion: "Needs conversion"
            case .converting: "Converting…"
            case .conversionFailed: "Conversion failed"
            case .loading: "Loading…"
            case .ready: "Ready"
            case .failed: "Could not load"
            }
        }
        return switch tab.kind {
        case .script: "0 words"
        case .stills: "8 frames"
        case .audio: "00:12.4"
        case .video: "00:12.4"
        case .subtitle: "No subtitle open"
        case .model3d: "No model open"
        case .html: "Local preview"
        case .delivery: "Not rendered"
        }
    }

    private func contextRight(for tab: EditorTab) -> String {
        if tab.kind == .script,
           let document = state.markdown.selectedDocument {
            return document.hasBOM
                ? "Markdown · UTF-8 BOM"
                : "Markdown · UTF-8"
        }
        if tab.kind == .subtitle,
           let document = state.subtitles.selectedDocument {
            return "\(document.format.displayName) · \(document.encoding.displayName)"
        }
        if tab.kind == .model3d,
           let document = state.models.selectedDocument {
            return "\(document.format.displayName) · three.js"
        }
        return switch tab.kind {
        case .script: "Markdown"
        case .stills: "2048 px · 2 need review"
        case .audio: "48 kHz · Stereo"
        case .video: "1920×1080 · H.264"
        case .subtitle: "SRT · WebVTT · ASS"
        case .model3d: "GLB · STL · 3MF · USDZ"
        case .html: "No network"
        case .delivery: "1920×1080 · H.264"
        }
    }
}

private struct Scrubber: View {
    @Bindable var state: AppState

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, AppTheme.Spacing.hairline)
            let fraction = min(
                max(
                    state.playhead / state.duration,
                    AppTheme.Preferences.unitRange.lowerBound
                ),
                AppTheme.Preferences.unitRange.upperBound
            )

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.appSeparator.opacity(AppTheme.Opacity.strongSoft))
                    .frame(height: AppTheme.Size.scrubberHeight)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(AppTheme.Size.scrubberHeight, width * fraction), height: AppTheme.Size.scrubberHeight)

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: AppTheme.Size.scrubberThumb, height: AppTheme.Size.scrubberThumb)
                    .appShadow(AppTheme.Shadow.playhead)
                    .offset(
                        x: min(
                            max(width * fraction - AppTheme.Size.scrubberThumbRadius, AppTheme.Spacing.zero),
                            width - AppTheme.Size.scrubberThumb
                        )
                    )
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: AppTheme.Spacing.zero)
                    .onChanged { value in
                        let newFraction = min(
                            max(
                                value.location.x / width,
                                AppTheme.Preferences.unitRange.lowerBound
                            ),
                            AppTheme.Preferences.unitRange.upperBound
                        )
                        state.playhead = newFraction * state.duration
                    }
            )
        }
        .frame(height: AppTheme.Size.scrubberHitHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playhead")
        .accessibilityValue("\(Int((state.playhead / state.duration) * 100)) percent")
    }
}
