import SwiftUI

struct VideoReviewView: View {
    let state: AppState

    var body: some View {
        if let asset = state.selectedAsset {
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
                takeLabel: "TAKE 03",
                status: state.status(for: asset)
            )
            .frame(maxWidth: 900)

            shotsCard
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func header(_ asset: ProductionAsset) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(asset.name)
                        .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                        .lineLimit(1)

                    StatusBadge(status: state.status(for: asset))
                }

                Text("\(asset.shortDetail) · 24 fps · Rec. 709")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            Button {
                state.editorMode = .compare
            } label: {
                Label("Compare", systemImage: "rectangle.split.2x1")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if state.status(for: asset) == .approved {
                Label("Approved", systemImage: "checkmark.circle.fill")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Button {
                    state.approve(asset)
                } label: {
                    Label("Approve", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var shotsCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Shots")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                Text("8 shots · 4 approved")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Select a frame to review")
                    .font(.system(size: AppTheme.FontSize.xxs))
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
                                .frame(width: 116, height: 65)

                                Text(String(format: "00:%02d", index * 2))
                                    .font(.system(size: AppTheme.FontSize.xxs, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.black.opacity(0.45)))
                                    .padding(4)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
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
    let status: ReviewStatus

    var body: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                ZStack {
                    CoastalSceneView(palette: palette)

                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.38),
                            Color.clear,
                            Color.black.opacity(0.52)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    VStack(spacing: 0) {
                        HStack(alignment: .top) {
                            takeBadge
                            Spacer()
                            Button {
                                state.editorMode = .compare
                            } label: {
                                Label("A/B", systemImage: "rectangle.split.2x1")
                                    .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                                    .padding(.horizontal, AppTheme.Spacing.sm)
                                    .padding(.vertical, AppTheme.Spacing.xs)
                                    .background(Capsule().fill(.ultraThinMaterial))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white)
                            .help("Compare takes")
                        }

                        Spacer()

                        Button {
                            state.togglePlayback()
                        } label: {
                            Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 21, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 52, height: 52)
                                .background(Circle().fill(.ultraThinMaterial))
                                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .help(state.isPlaying ? "Pause" : "Play")

                        Spacer()

                        VStack(spacing: AppTheme.Spacing.sm) {
                            if state.showCaptions, let segment = state.selectedTranscript {
                                Text(segment.text)
                                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, AppTheme.Spacing.sm)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: AppTheme.Radius.xs, style: .continuous)
                                            .fill(.black.opacity(0.52))
                                    )
                            }

                            HStack {
                                Text("\(TranscriptSegment.timecode(for: state.playhead)) / \(TranscriptSegment.timecode(for: state.duration))")
                                    .font(.system(size: AppTheme.FontSize.xxs, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.85))
                                Spacer()
                                Text("16:9 · 1080p")
                                    .font(.system(size: AppTheme.FontSize.xxs))
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                        }
                    }
                    .padding(AppTheme.Spacing.md)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                    .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }

    private var takeBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.color)
                .frame(width: 5, height: 5)
            Text(takeLabel)
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .tracking(1.0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(Capsule().fill(.ultraThinMaterial))
    }
}

struct VideoCompareView: View {
    let state: AppState

    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            header
            wipeStage
                .frame(maxWidth: 900)
            summaries
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Compare Takes")
                    .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                Text("Take 02 (approved) against \(state.selectedAsset?.name ?? "the current take")")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label("Playheads synced", systemImage: "link")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(.secondary)

            Button {
                state.togglePlayback()
            } label: {
                Label(state.isPlaying ? "Pause Both" : "Play Both", systemImage: state.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var wipeStage: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    let size = geometry.size
                    let splitX = size.width * state.compareSplit

                    ZStack {
                        CoastalSceneView(palette: .dusk)

                        CoastalSceneView(palette: .dawn)
                            .mask(alignment: .leading) {
                                Rectangle()
                                    .frame(width: splitX)
                            }

                        Rectangle()
                            .fill(.white.opacity(0.9))
                            .frame(width: 1.5)
                            .position(x: splitX, y: size.height / 2)

                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                            HStack(spacing: 2) {
                                Image(systemName: "chevron.left")
                                Image(systemName: "chevron.right")
                            }
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                        }
                        .position(x: splitX, y: size.height / 2)

                        VStack {
                            HStack {
                                compareLabel("A · TAKE 02", color: .green)
                                Spacer()
                                compareLabel("B · TAKE 03", color: .orange)
                            }
                            Spacer()
                            HStack {
                                Text("\(TranscriptSegment.timecode(for: state.playhead)) / \(TranscriptSegment.timecode(for: state.duration))")
                                    .font(.system(size: AppTheme.FontSize.xxs, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.85))
                                Spacer()
                                Text("Drag to wipe")
                                    .font(.system(size: AppTheme.FontSize.xxs))
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                        }
                        .padding(AppTheme.Spacing.md)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let fraction = value.location.x / max(size.width, 1)
                                state.compareSplit = min(max(fraction, 0.08), 0.92)
                            }
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                    .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }

    private func compareLabel(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .tracking(0.8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(Capsule().fill(.ultraThinMaterial))
    }

    private var summaries: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            summaryCard(
                letter: "A",
                name: "take-02.mp4",
                detail: "00:12.8 · Warmer read",
                status: .approved,
                tint: .green
            )

            summaryCard(
                letter: "B",
                name: state.selectedAsset?.name ?? "take-03.mp4",
                detail: "00:12.4 · Tighter pauses",
                status: state.selectedAsset.map { state.status(for: $0) } ?? .needsReview,
                tint: .orange
            )

            VStack(spacing: 4) {
                Text("Δ")
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("0.4s shorter")
                Text("2 open notes")
                Text("−1.2 LUFS")
            }
            .font(.system(size: AppTheme.FontSize.xxs))
            .foregroundStyle(.secondary)
            .frame(width: 104)
            .padding(.vertical, AppTheme.Spacing.sm)
        }
    }

    private func summaryCard(
        letter: String,
        name: String,
        detail: String,
        status: ReviewStatus,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(letter)
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(tint.opacity(0.12)))
                Text(name)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                Spacer()
                StatusBadge(status: status, compact: true)
            }

            Text(detail)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(.secondary)
        }
        .padding(AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCardStyle()
    }
}
