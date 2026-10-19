import SwiftUI

struct TranscriptView: View {
    let state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                header
                callout
                segmentList
                footer
            }
            .padding(AppTheme.Spacing.xl)
            .frame(maxWidth: AppTheme.Layout.pageMaxWidth, alignment: .leading)
            .background(Color.appText)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.surface, style: .continuous)
                    .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.surface, style: .continuous))
            .appShadow(AppTheme.Shadow.card)
            .padding(AppTheme.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.s3) {
                Text("TRANSCRIPT")
                    .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
                    .tracking(AppTheme.Tracking.display)
                    .foregroundStyle(.tertiary)

                Text("Tidewater — Ep. 01")
                    .font(.system(size: AppTheme.TypeScale.displaySmall, weight: .bold, design: .serif))

                Text("\(state.selectedAsset?.name ?? "take-03.mp4") · 00:12.4 · 4 segments")
                    .font(.system(size: AppTheme.TypeScale.xs))
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
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(Color.accentColor)
            Text("Edit the words to cut the audio.")
                .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous)
                .fill(Color.accentColor.opacity(AppTheme.Opacity.veil))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(AppTheme.Opacity.muted), lineWidth: AppTheme.BorderWidth.hairline)
        )
        .padding(.top, AppTheme.Spacing.lg)
        .padding(.bottom, AppTheme.Spacing.md)
    }

    private var segmentList: some View {
        VStack(spacing: AppTheme.Spacing.xxs) {
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
                .font(.system(size: AppTheme.TypeScale.xs, weight: .medium, design: .monospaced))
                .foregroundStyle(isSelected ? Color.accentColor : Color.appTertiaryLabel)
                .frame(width: AppTheme.Size.timecodeColumnWidth, alignment: .leading)
                .padding(.top, AppTheme.Spacing.s5)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.s6) {
                    Text(segment.speaker.uppercased())
                        .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
                        .tracking(AppTheme.Tracking.tight)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                    if hasNote {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: AppTheme.TypeScale.xxs))
                            .foregroundStyle(AppTheme.Palette.needsReview)
                            .help("Review note attached")
                    }
                }

                Text(segment.text)
                    .font(.system(size: AppTheme.TypeScale.xl, design: .serif))
                    .lineSpacing(AppTheme.LineSpacing.normal)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: AppTheme.Spacing.zero)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(AppTheme.Opacity.veil) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: AppTheme.Radius.line)
                    .fill(Color.accentColor)
                    .frame(width: AppTheme.BorderWidth.thick)
                    .padding(.vertical, AppTheme.Spacing.sm)
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
                    .font(.system(size: AppTheme.TypeScale.xs, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let asset = state.selectedAsset {
                BarIconButton(systemName: "text.bubble", help: "Request change") {
                    state.requestChange(for: asset)
                }
            }
        }
        .padding(.top, AppTheme.Spacing.lg)
    }
}
