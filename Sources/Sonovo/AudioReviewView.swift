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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(asset.name)
                        .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                        .lineLimit(1)

                    StatusBadge(status: state.status(for: asset))
                }

                Text("Narrator · \(asset.shortDetail) · 24-bit")
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

    private var waveformCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Waveform")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))

                Spacer()

                if let segment = state.selectedTranscript {
                    Text("\(segment.timecode) – \(TranscriptSegment.timecode(for: segment.end))")
                        .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text("48 kHz")
                    .font(.system(size: AppTheme.FontSize.xxs))
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
            .frame(height: 208)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
        }
        .appCardStyle()
    }

    private var transcriptCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Transcript")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))

                Text("Auto-aligned · \(state.transcript.count) segments")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(.secondary)

                Spacer()

                Label("Edit words to cut audio", systemImage: "text.cursor")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)

            Hairline()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(state.transcript) { segment in
                        TranscriptRow(state: state, segment: segment)
                    }
                }
                .padding(AppTheme.Spacing.sm)
            }

            Hairline()

            transcriptFooter
        }
        .frame(maxHeight: .infinity)
        .appCardStyle()
    }

    private var transcriptFooter: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if let segment = state.selectedTranscript {
                Text("Selected · \(segment.timecode)")
                    .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
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
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium, design: .monospaced))
                .foregroundStyle(isSelected ? Color.accentColor : Color.appTertiaryLabel)
                .frame(width: 54, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(segment.speaker.uppercased())
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                Text(segment.text)
                    .font(.system(size: AppTheme.FontSize.md))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .padding(.vertical, 6)
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

            compareCard(
                letter: "A",
                name: "vo-take-02.wav",
                detail: "Approved · 00:12.8 · Warmer read",
                status: .approved,
                duration: 12.8,
                selectedID: nil,
                tint: .green
            )

            compareCard(
                letter: "B",
                name: state.selectedAsset?.name ?? "vo-take-03.wav",
                detail: "Needs review · 00:12.4 · Tighter pauses",
                status: state.selectedAsset.map { state.status(for: $0) } ?? .needsReview,
                duration: state.duration,
                selectedID: state.selectedTranscriptID,
                tint: .orange
            )

            HStack(spacing: 0) {
                differenceItem(value: "0.4s", label: "shorter")
                differenceDivider
                differenceItem(value: "2", label: "open notes")
                differenceDivider
                differenceItem(value: "−1.2", label: "LUFS")
                differenceDivider
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
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(letter)
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(tint.opacity(0.12)))

                Text(name)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))

                StatusBadge(status: status, compact: true)

                Text(detail)
                    .font(.system(size: AppTheme.FontSize.xxs))
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
            .frame(height: 108)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
        }
        .appCardStyle()
    }

    private var differenceDivider: some View {
        Rectangle()
            .fill(Color.appSeparator)
            .frame(width: 1, height: 24)
    }

    private func differenceItem(value: String, label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: AppTheme.FontSize.md, weight: .semibold, design: .rounded))
            Text(label)
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
