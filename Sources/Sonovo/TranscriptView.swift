import SwiftUI

struct TranscriptView: View {
    let state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                callout
                segmentList
                footer
            }
            .padding(AppTheme.Spacing.xl)
            .frame(maxWidth: 760, alignment: .leading)
            .background(Color.appText)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                    .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
            .padding(AppTheme.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        .background(Color.appContent)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text("TRANSCRIPT")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.tertiary)

                Text("Tidewater — Ep. 01")
                    .font(.system(size: 24, weight: .bold, design: .serif))

                Text("\(state.selectedAsset?.name ?? "take-03.mp4") · 00:12.4 · 4 segments")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let asset = state.selectedAsset {
                StatusBadge(status: state.status(for: asset))
            }
        }
    }

    private var callout: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "text.cursor")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            Text("Edit the words to cut the audio.")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(Color.accentColor.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.16), lineWidth: AppTheme.BorderWidth.hairline)
        )
        .padding(.top, AppTheme.Spacing.lg)
        .padding(.bottom, AppTheme.Spacing.md)
    }

    private var segmentList: some View {
        VStack(spacing: 2) {
            ForEach(state.transcript) { segment in
                transcriptRow(segment)
            }
        }
    }

    private func transcriptRow(_ segment: TranscriptSegment) -> some View {
        let isSelected = state.selectedTranscriptID == segment.id
        let hasNote = segment.id == "seg-2" || segment.id == "seg-3"

        return HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Text(segment.timecode)
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium, design: .monospaced))
                .foregroundStyle(isSelected ? Color.accentColor : Color.appTertiaryLabel)
                .frame(width: 56, alignment: .leading)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(segment.speaker.uppercased())
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                    if hasNote {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help("Review note attached")
                    }
                }

                Text(segment.text)
                    .font(.system(size: 17, design: .serif))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.07) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .padding(.vertical, 8)
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

    private var footer: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if let segment = state.selectedTranscript {
                Text("Selected · \(segment.timecode) – \(TranscriptSegment.timecode(for: segment.end))")
                    .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let asset = state.selectedAsset {
                Button {
                    state.requestChange(for: asset)
                } label: {
                    Label("Request Change…", systemImage: "text.bubble")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.top, AppTheme.Spacing.lg)
    }
}
