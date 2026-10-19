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
        .frame(height: AppTheme.transportHeight)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.appSeparator)
                .frame(height: AppTheme.BorderWidth.hairline)
        }
    }

    private var terminalBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "terminal")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(.secondary)

            Text("Terminal")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))

            Text((state.terminalWorkingDirectory as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: AppTheme.Spacing.sm)

            Text("⌃`")
                .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                .foregroundStyle(.tertiary)

            Button("Restore Editor") {
                state.terminalPresentation = .split
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Hide") {
                state.terminalPresentation = .hidden
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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

            HStack(spacing: 3) {
                Text(TranscriptSegment.timecode(for: state.playhead))
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium, design: .monospaced))
                    .frame(width: 62, alignment: .leading)
                Text("/")
                    .foregroundStyle(.tertiary)
                Text(TranscriptSegment.timecode(for: state.duration))
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
            }
            .monospacedDigit()

            Scrubber(state: state)
                .frame(maxWidth: .infinity)

            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(.secondary)

                Slider(value: $state.volume, in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 66)
                    .help("Volume")

                Button {
                    state.showCaptions.toggle()
                } label: {
                    Text("CC")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 24, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(state.showCaptions ? Color.accentColor.opacity(0.16) : Color.clear)
                        )
                        .foregroundStyle(state.showCaptions ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(state.showCaptions ? "Hide captions" : "Show captions")

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
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(.secondary)

                Text(asset.name)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .lineLimit(1)

                Text(contextDetail(for: tab.kind))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.secondary)

                Spacer(minLength: AppTheme.Spacing.sm)

                Text(contextRight(for: tab.kind))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.tertiary)
            } else {
                Text("No editor open")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
    }

    private func contextDetail(for kind: AssetKind) -> String {
        switch kind {
        case .script: "1,240 words"
        case .stills: "8 frames"
        case .audio: "00:12.4"
        case .video: "00:12.4"
        case .html: "Local preview"
        case .delivery: "Not rendered"
        }
    }

    private func contextRight(for kind: AssetKind) -> String {
        switch kind {
        case .script: "Markdown · UTF-8"
        case .stills: "2048 px · 2 need review"
        case .audio: "48 kHz · Stereo"
        case .video: "1920×1080 · H.264"
        case .html: "No network"
        case .delivery: "1920×1080 · H.264"
        }
    }
}

private struct Scrubber: View {
    @Bindable var state: AppState

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let fraction = min(max(state.playhead / state.duration, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.appSeparator.opacity(0.55))
                    .frame(height: 4)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(4, width * fraction), height: 4)

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.16), radius: 1, y: 0.5)
                    .offset(x: min(max(width * fraction - 5, 0), width - 10))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let newFraction = min(max(value.location.x / width, 0), 1)
                        state.playhead = newFraction * state.duration
                    }
            )
        }
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playhead")
        .accessibilityValue("\(Int((state.playhead / state.duration) * 100)) percent")
    }
}
