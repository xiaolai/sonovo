import AppKit
import AVFoundation
import SonovoCore
import SwiftUI

/// The expanded video surface. Apple-style playback chrome floats over the
/// bottom of the picture; the cue text is never pushed out by a second bar.
struct SubtitlePreviewView: View {
    let workspace: SubtitleWorkspace
    let document: SubtitleDocument

    private var player: SubtitleMediaPlayer { workspace.player }

    var body: some View {
        ZStack(alignment: .bottom) {
            videoContent
                .contentShape(Rectangle())
                .onTapGesture {
                    if player.isReady {
                        player.togglePlay()
                    }
                }

            SubtitlePlayerBar(
                workspace: workspace,
                document: document,
                isOverVideo: true
            )
            .padding(AppTheme.Spacing.md)
        }
        .aspectRatio(
            AppTheme.Size.stageAspectWidth / AppTheme.Size.stageAspectHeight,
            contentMode: .fit
        )
        .frame(
            maxWidth: AppTheme.Subtitle.stageMaxWidth,
            maxHeight: AppTheme.Subtitle.stageMaxHeight
        )
        .frame(maxWidth: .infinity)
        .clipShape(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.surface,
                style: .continuous
            )
        )
        .shadow(
            color: AppTheme.Shadow.card.color,
            radius: AppTheme.Shadow.card.radius,
            x: AppTheme.Shadow.card.x,
            y: AppTheme.Shadow.card.y
        )
        .accessibilityLabel("Subtitle preview")
        .accessibilityHint(
            player.isReady ? "Play or pause" : "Open media to preview"
        )
    }

    private var videoContent: some View {
        ZStack {
            AppTheme.Palette.black

            if player.isReady, player.hasVideo {
                PlayerLayerView(player: player.player)
            } else {
                stagePlaceholder
            }
        }
    }

    @ViewBuilder
    private var stagePlaceholder: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "play.rectangle")
                .font(
                    .system(
                        size: AppTheme.IconSize.render,
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(
                    AppTheme.Palette.white.opacity(AppTheme.Opacity.secondary)
                )

            if player.isLoading {
                Text("Loading media…")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(
                        AppTheme.Palette.white
                            .opacity(AppTheme.Opacity.heavySoft)
                    )
            } else if player.isReady {
                Text(mediaName)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(
                        AppTheme.Palette.white
                            .opacity(AppTheme.Opacity.heavySoft)
                    )
            } else {
                Text("Open media to preview")
                    .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
                    .foregroundStyle(
                        AppTheme.Palette.white.opacity(AppTheme.Opacity.near)
                    )
                Button("Open Media…") {
                    workspace.presentOpenMediaPanel(for: document)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(AppTheme.Palette.white)

                if let error = player.errorMessage {
                    Text(error)
                        .font(.system(size: AppTheme.TypeScale.xxs))
                        .foregroundStyle(AppTheme.Palette.needsReview)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: AppTheme.Layout.emptyDescriptionMaxWidth)
                }
            }
        }
        .padding(AppTheme.Spacing.lg)
    }

    private var mediaName: String {
        workspace.mediaURL(for: document)?.lastPathComponent
            ?? "No media"
    }
}

enum SubtitlePlayerBarLayout {
    case stacked
    case inline
}

/// The playback bar. It is the same component in both states: floating over
/// the video when expanded, docked inline in the page header when collapsed.
struct SubtitlePlayerBar: View {
    let workspace: SubtitleWorkspace
    let document: SubtitleDocument
    var isOverVideo: Bool = false
    var layout: SubtitlePlayerBarLayout = .stacked

    private var player: SubtitleMediaPlayer { workspace.player }
    private var mapStyle: SubtitleCueMapStyle {
        isOverVideo ? .overlay : .panel
    }

    private var foreground: Color {
        isOverVideo ? AppTheme.Palette.white : AppTheme.Palette.label
    }

    private var secondaryForeground: Color {
        isOverVideo
            ? AppTheme.Palette.white.opacity(AppTheme.Opacity.heavySoft)
            : AppTheme.Palette.secondaryLabel
    }

    @ViewBuilder
    var body: some View {
        if isOverVideo {
            // Force the dark appearance for chrome placed over video. The
            // media menu's popup otherwise follows the light app appearance
            // while the bar sits on a dark picture.
            content
                .environment(\.colorScheme, .dark)
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .stacked:
            stackedBody
        case .inline:
            inlineBody
        }
    }

    private var stackedBody: some View {
        VStack(spacing: AppTheme.Spacing.s6) {
            cueMap(tooltipBelow: false)

            HStack(spacing: AppTheme.Spacing.sm) {
                playButton
                timeDisplay
                Spacer(minLength: AppTheme.Spacing.sm)
                videoToggle
                mediaMenu(compact: false)
            }
            .frame(height: AppTheme.ControlSize.large)
        }
        .padding(.horizontal, AppTheme.Spacing.s10)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background {
            if isOverVideo {
                RoundedRectangle(
                    cornerRadius: AppTheme.Radius.panel,
                    style: .continuous
                )
                .fill(
                    AppTheme.Palette.black.opacity(AppTheme.Opacity.secondary)
                )
            }
        }
    }

    private var inlineBody: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            playButton
            timeDisplay
            cueMap(tooltipBelow: true)
                .frame(maxWidth: .infinity)
            videoToggle
            mediaMenu(compact: true)
        }
        .frame(height: AppTheme.ControlSize.large)
        .padding(.horizontal, AppTheme.Spacing.sm)
    }

    private func cueMap(tooltipBelow: Bool) -> some View {
        SubtitleCueMap(
            cues: document.parsed.cues.filter(\.hasValidTiming),
            durationMilliseconds: durationMilliseconds,
            currentMilliseconds: player.isReady
                ? player.currentMilliseconds
                : 0,
            activeOrdinals: activeOrdinals,
            selectedOrdinal: selectedOrdinal,
            style: mapStyle,
            tooltipBelow: tooltipBelow
        ) { milliseconds in
            seek(to: milliseconds)
        }
    }

    private var videoToggle: some View {
        PlayerIconButton(
            systemName: workspace.previewMode == .collapsed
                ? "chevron.down"
                : "chevron.up",
            help: workspace.previewMode == .collapsed
                ? "Show Video"
                : "Hide Video",
            tint: foreground
        ) {
            DispatchQueue.main.async {
                workspace.togglePreviewMode()
            }
        }
    }

    private var playButton: some View {
        Button {
            player.togglePlay()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(
                    .system(
                        size: AppTheme.TypeScale.md,
                        weight: .semibold
                    )
                )
                .foregroundStyle(foreground)
                .frame(
                    width: AppTheme.ControlSize.large,
                    height: AppTheme.ControlSize.large
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!player.isReady)
        .help(player.isPlaying ? "Pause" : "Play")
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }

    private var timeDisplay: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Text(SubtitleTimecode.display(seconds: player.currentTime))
                .font(
                    .system(
                        size: AppTheme.TypeScale.sm,
                        weight: .medium,
                        design: .monospaced
                    )
                )
                .foregroundStyle(foreground)
            Text("/")
                .foregroundStyle(secondaryForeground)
            Text(SubtitleTimecode.display(seconds: player.duration))
                .font(
                    .system(
                        size: AppTheme.TypeScale.sm,
                        design: .monospaced
                    )
                )
                .foregroundStyle(secondaryForeground)
        }
        .monospacedDigit()
    }

    private func mediaMenu(compact: Bool) -> some View {
        Menu {
            Button("Open Media…") {
                workspace.presentOpenMediaPanel(for: document)
            }
            if let url = workspace.mediaURL(for: document) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Divider()
                Button("Detach Media") {
                    workspace.detachMedia(for: document)
                }
            }
        } label: {
            if compact {
                Image(systemName: "film")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(secondaryForeground)
                    .frame(
                        width: AppTheme.ControlSize.medium,
                        height: AppTheme.ControlSize.regular
                    )
                    .contentShape(Rectangle())
            } else {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "film")
                        .font(.system(size: AppTheme.TypeScale.xxs))
                    Text(mediaName)
                        .font(.system(size: AppTheme.TypeScale.xxs))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(secondaryForeground)
                .contentShape(Rectangle())
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(
            compact
                ? "\(mediaName) · \(player.isReady ? "Preview media" : "Open media to preview")"
                : (player.isReady ? "Preview media" : "Open media to preview")
        )
        .accessibilityLabel("Preview media")
    }

    private var mediaName: String {
        workspace.mediaURL(for: document)?.lastPathComponent
            ?? "No media"
    }

    private var durationMilliseconds: Int {
        max(
            max(
                player.isReady ? player.durationMilliseconds : 0,
                document.durationMilliseconds
            ),
            1
        )
    }

    private var activeOrdinals: Set<Int> {
        guard player.isReady else { return [] }
        return Set(
            document.parsed.timeline.activeOrdinals(
                atMilliseconds: player.currentMilliseconds
            )
        )
    }

    private var selectedOrdinal: Int? {
        let active = document.parsed.timeline.activeOrdinals(
            atMilliseconds: player.currentMilliseconds
        )
        return active.first
    }

    private func seek(to milliseconds: Int) {
        guard player.isReady else { return }
        player.seek(toMilliseconds: max(0, milliseconds))
    }
}

private struct PlayerIconButton: View {
    let systemName: String
    let help: String
    var isSelected = false
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
                .frame(
                    width: AppTheme.ControlSize.medium,
                    height: AppTheme.ControlSize.regular
                )
                .foregroundStyle(
                    isSelected ? Color.accentColor : tint
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The AVPlayerLayer host for video preview.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerHostView, context: Context) {
        nsView.playerLayer.player = player
    }
}

final class PlayerLayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
