import SonovoWorkspaceHost
import SonovoFeatureAPI
import SonovoMediaFeature
import SonovoDomainTypes
import SonovoDesignSystem
import SwiftUI

struct TransportBar: View {
    @Bindable var state: AppState

    private var isMediaTab: Bool {
        guard state.liveProject.isDemo,
              let kind = state.selectedTab?.kind else {
            return false
        }
        // Audio now has a real MediaAssetView transport. Only the demo video
        // still uses the shared sample transport.
        return kind == .video
    }

    var body: some View {
        Group {
            if state.terminalPresentation == .full {
                terminalBar
            } else if isMediaTab {
                mediaTransport
            } else if let transport = featureTransport {
                transport
            } else {
                contextBar
            }
        }
        .frame(height: AppTheme.Layout.transportHeight)
        .background(Color.appText)
    }

    private var featureTransport: AnyView? {
        guard !state.liveProject.isDemo, let id = state.liveProject.selectedFeatureID,
              let contribution = state.liveProject.featureSessions.session(for: id)?.transport else { return nil }
        return contribution.makeView(EditorRequest(project: state.liveProject, asset: state.liveProject.selectedAsset,
            isVisible: state.terminalPresentation != .full))
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

    private struct Context {
        let icon: String
        let name: String
        let detail: String
        let right: String
    }

    private var currentContext: Context? {
        if !state.liveProject.isDemo,
           let asset = state.liveProject.selectedAsset {
            return Context(
                icon: asset.kind.icon,
                name: asset.name,
                detail: realDetail(for: asset),
                right: realRight(for: asset)
            )
        }
        if !state.liveProject.isDemo,
           let tab = state.selectedTab, let kind = tab.workspaceKind,
           let identity = state.liveProject.workspaceDocumentIdentity(for: tab) {
            return Context(
                icon: kind.icon,
                name: identity.name,
                detail: identity.detail,
                right: kind.rawValue.capitalized
            )
        }
        if let tab = state.selectedTab,
           let asset = state.liveProject.sampleProductionAsset(id: tab.assetID) {
            return Context(
                icon: tab.kind.icon,
                name: state.displayName(for: asset),
                detail: contextDetail(for: tab),
                right: contextRight(for: tab)
            )
        }
        return nil
    }

    private var contextBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if let context = currentContext {
                Image(systemName: context.icon)
                    .font(.system(size: AppTheme.TypeScale.sm))
                    .foregroundStyle(.secondary)

                Text(context.name)
                    .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
                    .lineLimit(1)

                Text(context.detail)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)

                Spacer(minLength: AppTheme.Spacing.sm)

                Text(context.right)
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

    private func realDetail(for asset: ProjectAsset) -> String {
        guard let tab = state.selectedTab else {
            return asset.fileExtension.uppercased()
        }
        if let summary = featureSummary(for: tab), summary.summarizesFileTab { return summary.detail }
        return asset.fileExtension.uppercased()
    }

    private func realRight(for asset: ProjectAsset) -> String {
        if let tab = state.selectedTab, let summary = featureSummary(for: tab), summary.summarizesFileTab {
            return summary.trailing
        }
        return ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file)
    }

    private func featureSummary(for tab: EditorTab) -> FeatureStatusSummary? {
        guard let adapter = state.liveProject.documentAdapter(for: tab) else { return nil }
        return state.liveProject.featureSessions.session(for: adapter.featureID)?.statusSummary
    }

    private func contextDetail(for tab: EditorTab) -> String {
        if let summary = featureSummary(for: tab) { return summary.detail }
        return switch tab.kind {
        case .script: "0 words"
        case .stills: "8 frames"
        case .audio: state.selectedAsset?.shortDetail ?? "Audio"
        case .video: "00:12.4"
        case .subtitle: "No subtitle open"
        case .model3d: "No model open"
        case .html: "Local preview"
        case .delivery: "Not rendered"
        case .code: "No code file open"
        case .mdx: "No MDX document open"
        case .timeline: "3 tracks"
        case .document: "Document"
        case .image: "Image"
        case .archive: "Archive"
        case .other: "File"
        }
    }

    /// The sample audio detail is already the real file's duration, sample
    /// rate, and channel count; keep the context bar in step with it.
    private var selectedAudioRight: String {
        guard let detail = state.selectedAsset?.detail else { return "WAV" }
        let parts = detail.components(separatedBy: " · ")
        return parts.count > 1
            ? parts.dropFirst().joined(separator: " · ")
            : "WAV"
    }

    private func contextRight(for tab: EditorTab) -> String {
        if let summary = featureSummary(for: tab) { return summary.trailing }
        return switch tab.kind {
        case .script: "Markdown"
        case .stills: "2048 px · 8 frames"
        case .audio: selectedAudioRight
        case .video: "1920×1080 · H.264"
        case .subtitle: "SRT · WebVTT · ASS"
        case .model3d: "GLB · STL · 3MF · USDZ"
        case .html: "No remote loads"
        case .delivery: "1920×1080 · H.264"
        case .code: "UTF-8"
        case .mdx: "MDX · UTF-8"
        case .timeline: "Video · Voice · Music"
        case .document: "Preview"
        case .image: "Local file"
        case .archive: "Metadata"
        case .other: "Local file"
        }
    }
}

private struct Scrubber: View {
    @Bindable var state: AppState

    /// The playhead's fraction of the duration, or zero while the duration
    /// is unknown. Dividing by zero yields NaN or infinity, which a raw
    /// `Int(_:)` conversion would trap on.
    private var fraction: Double {
        guard state.duration.isFinite,
              state.duration > 0,
              state.playhead.isFinite else {
            return 0
        }
        return min(
            max(
                state.playhead / state.duration,
                AppTheme.Preferences.unitRange.lowerBound
            ),
            AppTheme.Preferences.unitRange.upperBound
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, AppTheme.Spacing.hairline)
            let fraction = self.fraction

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
        .accessibilityValue(
            "\(NumericConversion.clamped(fraction * 100, to: 0...100)) percent"
        )
    }
}
