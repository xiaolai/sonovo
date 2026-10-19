import SwiftUI

struct AudioReviewView: View {
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

            waveformCard
                .layoutPriority(0)

            transcriptCard
                .layoutPriority(1)
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func header(_ asset: ProductionAsset) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(asset.name)
                        .font(.system(size: AppTheme.TypeScale.lg, weight: .semibold))
                        .lineLimit(1)

                    StatusBadge(status: state.status(for: asset))
                }

                Text("Narrator · \(asset.shortDetail) · 24-bit")
                    .font(.system(size: AppTheme.TypeScale.xs))
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
                    .font(.system(size: AppTheme.TypeScale.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Palette.approved)
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

    private var waveformCard: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Waveform")
                    .font(.system(size: AppTheme.TypeScale.sm, weight: .semibold))

                Spacer()

                if let segment = state.selectedTranscript {
                    Text("\(segment.timecode) – \(TranscriptSegment.timecode(for: segment.end))")
                        .font(.system(size: AppTheme.TypeScale.xs, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text("48 kHz")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.top, AppTheme.Spacing.sm)

            WaveformView(
                duration: state.duration,
                segments: state.transcript,
                selectedID: state.selectedTranscriptID,
                playhead: state.playhead
            )
            .frame(height: AppTheme.Size.waveformHeight)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
        }
        .appCardStyle()
    }

    private var transcriptCard: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Transcript")
                    .font(.system(size: AppTheme.TypeScale.sm, weight: .semibold))

                Text("Auto-aligned · \(state.transcript.count) segments")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.secondary)

                Spacer()

                Label("Edit words to cut audio", systemImage: "text.cursor")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)

            ScrollView {
                LazyVStack(spacing: AppTheme.Spacing.xxs) {
                    ForEach(state.transcript) { segment in
                        TranscriptRow(state: state, segment: segment)
                    }
                }
                .padding(AppTheme.Spacing.sm)
            }

            transcriptFooter
        }
        .frame(maxHeight: .infinity)
        .appCardStyle()
    }

    private var transcriptFooter: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if let segment = state.selectedTranscript {
                Text("Selected · \(segment.timecode)")
                    .font(.system(size: AppTheme.TypeScale.xs, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            Button {
                if let segment = state.selectedTranscript {
                    state.playhead = segment.start
                    state.isPlaying = true
                }
            } label: {
                Label("Play from Here", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.selectedTranscript == nil)

            Button {
                state.inspectorVisible = true
                state.inspectorTab = .notes
            } label: {
                Label("Add Note", systemImage: "text.bubble")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let asset = state.selectedAsset {
                Button {
                    state.requestChange(for: asset)
                } label: {
                    Label("Request Change…", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
    }
}

private struct TranscriptRow: View {
    let state: AppState
    let segment: TranscriptSegment

    private var isSelected: Bool {
        state.selectedTranscriptID == segment.id
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Text(segment.timecode)
                .font(.system(size: AppTheme.TypeScale.xs, weight: .medium, design: .monospaced))
                .foregroundStyle(isSelected ? Color.accentColor : Color.appTertiaryLabel)
                .frame(width: AppTheme.Size.timecodeWidth, alignment: .leading)
                .padding(.top, AppTheme.Spacing.xxs)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.s3) {
                Text(segment.speaker.uppercased())
                    .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                Text(segment.text)
                    .font(.system(size: AppTheme.TypeScale.md))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: AppTheme.Spacing.zero)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(AppTheme.Opacity.faint) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: AppTheme.Radius.line)
                    .fill(Color.accentColor)
                    .frame(width: AppTheme.BorderWidth.thick)
                    .padding(.vertical, AppTheme.Spacing.s6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            state.selectTranscript(segment.id)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct AudioCompareView: View {
    let state: AppState

    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.sm) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text("Compare Takes")
                        .font(.system(size: AppTheme.TypeScale.lg, weight: .semibold))
                    Text("Take 02 (approved) against \(state.selectedAsset?.name ?? "the current take")")
                        .font(.system(size: AppTheme.TypeScale.xs))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Label("Playheads synced", systemImage: "link")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)

                Button {
                    state.togglePlayback()
                } label: {
                    Label(state.isPlaying ? "Pause Both" : "Play Both", systemImage: state.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            compareCard(
                letter: "A",
                name: "vo-take-02.wav",
                detail: "Approved · 00:12.8 · Warmer read",
                status: .approved,
                duration: 12.8,
                selectedID: nil,
                tint: AppTheme.Palette.approved
            )

            compareCard(
                letter: "B",
                name: state.selectedAsset?.name ?? "vo-take-03.wav",
                detail: "Needs review · 00:12.4 · Tighter pauses",
                status: state.selectedAsset.map { state.status(for: $0) } ?? .needsReview,
                duration: state.duration,
                selectedID: state.selectedTranscriptID,
                tint: AppTheme.Palette.needsReview
            )

            HStack(spacing: AppTheme.Spacing.lg) {
                differenceItem(value: "0.4s", label: "shorter")
                differenceItem(value: "2", label: "open notes")
                differenceItem(value: "−1.2", label: "LUFS")
                differenceItem(value: "1", label: "line re-read")
            }
            .padding(.vertical, AppTheme.Spacing.sm)
            .frame(maxWidth: .infinity)
            .appCardStyle()
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func compareCard(
        letter: String,
        name: String,
        detail: String,
        status: ReviewStatus,
        duration: Double,
        selectedID: String?,
        tint: Color
    ) -> some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(letter)
                    .font(.system(size: AppTheme.TypeScale.xxs, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: AppTheme.Size.letterBadge, height: AppTheme.Size.letterBadge)
                    .background(Circle().fill(tint.opacity(AppTheme.Opacity.tint)))

                Text(name)
                    .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))

                StatusBadge(status: status, compact: true)

                Text(detail)
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.top, AppTheme.Spacing.sm)

            WaveformView(
                duration: duration,
                segments: state.transcript,
                selectedID: selectedID,
                playhead: min(state.playhead, duration)
            )
            .frame(height: AppTheme.Size.compareWaveformHeight)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
        }
        .appCardStyle()
    }

    private func differenceItem(value: String, label: String) -> some View {
        VStack(spacing: AppTheme.Spacing.hairline) {
            Text(value)
                .font(.system(size: AppTheme.TypeScale.md, weight: .semibold, design: .rounded))
            Text(label)
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
