import SwiftUI

struct VideoPlayerView: View {
    let state: AppState
    let project: Project

    private var selectedAsset: ProductionAsset? {
        state.selectedAsset(in: project)
    }

    var body: some View {
        if let asset = selectedAsset {
            content(asset)
        } else {
            EmptyEditorView()
        }
    }

    private func content(_ asset: ProductionAsset) -> some View {
        VStack(spacing: AppTheme.Spacing.md) {
            header(asset)

            VideoStageView(
                state: state,
                palette: .dawn,
                takeLabel: "TAKE 03"
            )
            .frame(maxWidth: AppTheme.Layout.mediaMaxWidth)

            shotsCard
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func header(_ asset: ProductionAsset) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(asset.name)
                    .font(.system(size: AppTheme.TypeScale.lg, weight: .semibold))
                    .lineLimit(1)

                Text("\(asset.shortDetail) · 24 fps · Rec. 709")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            BarIconButton(
                systemName: "rectangle.split.2x1",
                help: "Compare takes"
            ) {
                state.editorMode = .compare
            }
        }
    }

    private var shotsCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Shots")
                    .font(.system(size: AppTheme.TypeScale.sm, weight: .semibold))
                Text("8 shots")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Select a frame")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.tertiary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    ForEach(0..<8, id: \.self) { index in
                        Button {
                            state.selectedShotIndex = index
                        } label: {
                            ZStack(alignment: .bottomLeading) {
                                CoastalSceneView(
                                    palette: CoastalPalette.stills[index % CoastalPalette.stills.count],
                                    showsBoat: index % 2 == 0
                                )
                                .frame(width: AppTheme.Size.thumbnailWidth, height: AppTheme.Size.thumbnailHeight)

                                Text(String(format: "00:%02d", index * 2))
                                    .font(.system(size: AppTheme.TypeScale.xxs, design: .monospaced))
                                    .foregroundStyle(AppTheme.Palette.white)
                                    .padding(.horizontal, AppTheme.Spacing.xs)
                                    .padding(.vertical, AppTheme.Spacing.xxs)
                                    .background(Capsule().fill(AppTheme.Palette.black.opacity(AppTheme.Opacity.wash)))
                                    .padding(AppTheme.Spacing.xs)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                                    .strokeBorder(
                                        state.selectedShotIndex == index ? Color.accentColor : Color.clear,
                                        lineWidth: AppTheme.BorderWidth.thick
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Show shot \(index + 1)")
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .appCardStyle()
    }
}

struct VideoStageView: View {
    let state: AppState
    let palette: CoastalPalette
    let takeLabel: String

    var body: some View {
        Color.clear
            .aspectRatio(AppTheme.Size.stageAspectWidth / AppTheme.Size.stageAspectHeight, contentMode: .fit)
            .overlay {
                ZStack {
                    CoastalSceneView(palette: palette)

                    LinearGradient(
                        colors: [
                            AppTheme.Palette.black.opacity(AppTheme.Opacity.veilStrong),
                            Color.clear,
                            AppTheme.Palette.black.opacity(AppTheme.Opacity.halfStrong)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    VStack(spacing: AppTheme.Spacing.zero) {
                        HStack(alignment: .top) {
                            takeBadge
                            Spacer()
                            Button {
                                state.editorMode = .compare
                            } label: {
                                Image(systemName: "rectangle.split.2x1")
                                    .font(.system(size: AppTheme.TypeScale.xxs, weight: .medium))
                                    .padding(.horizontal, AppTheme.Spacing.sm)
                                    .padding(.vertical, AppTheme.Spacing.xs)
                                    .background(Capsule().fill(AppTheme.Surface.mediaOverlay))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.Palette.white)
                            .help("Compare takes")
                            .accessibilityLabel("Compare takes")
                        }

                        Spacer()

                        Button {
                            state.togglePlayback()
                        } label: {
                            Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: AppTheme.TypeScale.hero, weight: .medium))
                                .foregroundStyle(AppTheme.Palette.white)
                                .frame(width: AppTheme.IconSize.play, height: AppTheme.IconSize.play)
                                .background(Circle().fill(AppTheme.Surface.mediaOverlay))
                                .overlay(Circle().strokeBorder(AppTheme.Palette.white.opacity(AppTheme.Opacity.border), lineWidth: AppTheme.BorderWidth.hairline))
                        }
                        .buttonStyle(.plain)
                        .help(state.isPlaying ? "Pause" : "Play")
                        .accessibilityLabel(state.isPlaying ? "Pause" : "Play")

                        Spacer()

                        VStack(spacing: AppTheme.Spacing.sm) {
                            if state.showCaptions, let segment = state.currentTranscript {
                                Text(segment.text)
                                    .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
                                    .foregroundStyle(AppTheme.Palette.white)
                                    .padding(.horizontal, AppTheme.Spacing.sm)
                                    .padding(.vertical, AppTheme.Spacing.xs)
                                    .background(
                                        RoundedRectangle(cornerRadius: AppTheme.Radius.micro, style: .continuous)
                                            .fill(AppTheme.Palette.black.opacity(AppTheme.Opacity.halfStrong))
                                    )
                            }

                            HStack {
                                Text("\(TranscriptSegment.timecode(for: state.playhead)) / \(TranscriptSegment.timecode(for: state.duration))")
                                    .font(.system(size: AppTheme.TypeScale.xxs, design: .monospaced))
                                    .foregroundStyle(AppTheme.Palette.white.opacity(AppTheme.Opacity.near))
                                Spacer()
                                Text("16:9 · 1080p")
                                    .font(.system(size: AppTheme.TypeScale.xxs))
                                    .foregroundStyle(AppTheme.Palette.white.opacity(AppTheme.Opacity.heavy))
                            }
                        }
                    }
                    .padding(AppTheme.Spacing.md)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.surface, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.surface, style: .continuous)
                    .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
            )
            .appShadow(AppTheme.Shadow.media)
    }

    private var takeBadge: some View {
        HStack(spacing: AppTheme.Spacing.s5) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: AppTheme.IconSize.dotSmall, height: AppTheme.IconSize.dotSmall)
            Text(takeLabel)
                .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
                .tracking(AppTheme.Tracking.widest)
        }
        .foregroundStyle(AppTheme.Palette.white)
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(Capsule().fill(AppTheme.Surface.mediaOverlay))
    }
}

struct VideoCompareView: View {
    let state: AppState
    let project: Project

    private var selectedAsset: ProductionAsset? {
        state.selectedAsset(in: project)
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            header
            wipeStage
                .frame(maxWidth: AppTheme.Layout.mediaMaxWidth)
            summaries
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Compare Takes")
                    .font(.system(size: AppTheme.TypeScale.lg, weight: .semibold))
                Text("Take 02 against \(selectedAsset?.name ?? "the current take")")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label("Playheads synced", systemImage: "link")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)

            BarIconButton(
                systemName: state.isPlaying ? "pause.fill" : "play.fill",
                help: state.isPlaying ? "Pause both" : "Play both"
            ) {
                state.togglePlayback()
            }
        }
    }

    private var wipeStage: some View {
        Color.clear
            .aspectRatio(AppTheme.Size.stageAspectWidth / AppTheme.Size.stageAspectHeight, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    WipeStageContent(state: state, size: geometry.size)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.surface, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.surface, style: .continuous)
                    .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
            )
            .appShadow(AppTheme.Shadow.media)
    }

    private var summaries: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            summaryCard(
                letter: "A",
                name: "take-02.mp4",
                detail: "00:12.8 · Warmer read",
                tint: Color.accentColor
            )

            summaryCard(
                letter: "B",
                name: selectedAsset?.name ?? "take-03.mp4",
                detail: "00:12.4 · Tighter pauses",
                tint: Color.secondary
            )

            VStack(spacing: AppTheme.Spacing.xs) {
                Text("Δ")
                    .font(.system(size: AppTheme.TypeScale.md, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("0.4s shorter")
                Text("−1.2 LUFS")
                Text("1 line re-read")
            }
            .font(.system(size: AppTheme.TypeScale.xxs))
            .foregroundStyle(.secondary)
            .frame(width: AppTheme.Size.compareSummaryWidth)
            .padding(.vertical, AppTheme.Spacing.sm)
        }
    }

    private func summaryCard(
        letter: String,
        name: String,
        detail: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s5) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(letter)
                    .font(.system(size: AppTheme.TypeScale.xxs, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: AppTheme.Size.letterBadge, height: AppTheme.Size.letterBadge)
                    .background(Circle().fill(tint.opacity(AppTheme.Opacity.tint)))
                Text(name)
                    .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
                Spacer()
            }

            Text(detail)
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
        }
        .padding(AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCardStyle()
    }
}

/// The wipe comparison surface: two scenes, the split line and handle, the
/// labels, and the drag that moves the split.
private struct WipeStageContent: View {
    let state: AppState
    let size: CGSize

    private var splitX: CGFloat {
        size.width * state.compareSplit
    }

    var body: some View {
        ZStack {
            CoastalSceneView(palette: .dusk)

            CoastalSceneView(palette: .dawn)
                .mask(alignment: .leading) {
                    Rectangle()
                        .frame(width: splitX)
                }

            Rectangle()
                .fill(AppTheme.Palette.white.opacity(AppTheme.Opacity.dark))
                .frame(width: AppTheme.BorderWidth.medium)
                .position(x: splitX, y: size.height / 2)

            handle
            labels
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: AppTheme.Spacing.zero)
                .onChanged { value in
                    let fraction = value.location.x
                        / max(size.width, AppTheme.Spacing.hairline)
                    state.compareSplit = min(
                        max(fraction, AppTheme.Layout.compareMinSplit),
                        AppTheme.Layout.compareMaxSplit
                    )
                }
        )
    }

    private var handle: some View {
        ZStack {
            Circle()
                .fill(AppTheme.Surface.mediaOverlay)
                .frame(
                    width: AppTheme.Size.compareHandle,
                    height: AppTheme.Size.compareHandle
                )
                .overlay(
                    Circle().strokeBorder(
                        AppTheme.Palette.white.opacity(
                            AppTheme.Opacity.secondary
                        ),
                        lineWidth: AppTheme.BorderWidth.hairline
                    )
                )
            HStack(spacing: AppTheme.Spacing.xxs) {
                Image(systemName: "chevron.left")
                Image(systemName: "chevron.right")
            }
            .font(.system(size: AppTheme.TypeScale.micro, weight: .bold))
            .foregroundStyle(AppTheme.Palette.white)
        }
        .position(x: splitX, y: size.height / 2)
    }

    private var labels: some View {
        VStack {
            HStack {
                compareLabel("A · TAKE 02", color: Color.accentColor)
                Spacer()
                compareLabel("B · TAKE 03", color: Color.secondary)
            }
            Spacer()
            HStack {
                Text(
                    "\(TranscriptSegment.timecode(for: state.playhead))"
                        + " / \(TranscriptSegment.timecode(for: state.duration))"
                )
                .font(
                    .system(
                        size: AppTheme.TypeScale.xxs,
                        design: .monospaced
                    )
                )
                .foregroundStyle(
                    AppTheme.Palette.white.opacity(AppTheme.Opacity.near)
                )
                Spacer()
                Text("Drag to wipe")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(
                        AppTheme.Palette.white.opacity(
                            AppTheme.Opacity.heavy
                        )
                    )
            }
        }
        .padding(AppTheme.Spacing.md)
    }

    private func compareLabel(_ text: String, color: Color) -> some View {
        HStack(spacing: AppTheme.Spacing.s5) {
            Circle()
                .fill(color)
                .frame(
                    width: AppTheme.IconSize.dotSmall,
                    height: AppTheme.IconSize.dotSmall
                )
            Text(text)
                .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
                .tracking(AppTheme.Tracking.wide)
        }
        .foregroundStyle(AppTheme.Palette.white)
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(Capsule().fill(AppTheme.Surface.mediaOverlay))
    }
}
