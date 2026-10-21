import SonovoCore
import SwiftUI

/// One cue row in the list. The words lead; timing, warnings, and actions sit
/// quietly underneath or at the trailing edge. There is no per-row border and
/// no selection ring: the active cue is a soft tinted background.
struct SubtitleCueRow: View {
    let workspace: SubtitleWorkspace
    let document: SubtitleDocument
    let cue: SubtitleCue
    let isActive: Bool
    @Binding var editingOrdinal: Int?
    @Binding var draftText: String
    @FocusState.Binding var focusedCue: Int?
    let onSelect: () -> Void
    let onBeginEditing: () -> Void
    let onCommitText: () -> Void

    private enum TimingField: Hashable {
        case start
        case end
    }

    @State private var startText = ""
    @State private var endText = ""
    @State private var timingError: String?
    @State private var isHovering = false
    @FocusState private var timingFocus: TimingField?

    private var canEdit: Bool {
        !document.isReadOnly && document.parsed.errorCount == 0
    }

    private var isEditing: Bool {
        editingOrdinal == cue.ordinal
    }

    private var displayText: String {
        SubtitleText.plainText(cue.rawText, format: document.format)
    }

    private var warnings: [SubtitleDiagnostic] {
        document.parsed.diagnostics(forCueOrdinal: cue.ordinal)
    }

    private var rowBackground: Color {
        if isActive {
            return Color.accentColor.opacity(AppTheme.Opacity.tintSoft)
        }
        if isHovering {
            return Color.primary.opacity(AppTheme.Opacity.ghost)
        }
        return Color.clear
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                Text("\(cue.ordinal + 1)")
                    .font(
                        .system(
                            size: AppTheme.TypeScale.xxs,
                            weight: .medium,
                            design: .monospaced
                        )
                    )
                    .foregroundStyle(.tertiary)
                    .frame(
                        width: AppTheme.Subtitle.cueIndexWidth,
                        alignment: .trailing
                    )
                    .padding(.top, AppTheme.Spacing.xs)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    textSection
                    metadataRow
                    if let timingError {
                        Text(timingError)
                            .font(.system(size: AppTheme.TypeScale.xxs))
                            .foregroundStyle(AppTheme.Palette.warning)
                    }
                }

                Spacer(minLength: AppTheme.Spacing.xxs)

                playButton
                    .padding(.top, AppTheme.Spacing.xxs)
            }
            .padding(.vertical, AppTheme.Spacing.md)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .background(
                RoundedRectangle(
                    cornerRadius: AppTheme.Radius.panel,
                    style: .continuous
                )
                .fill(rowBackground)
            )
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
            .onHover { isHovering = $0 }

            Divider()
                .padding(.leading, AppTheme.Subtitle.cueDividerInset)
        }
        .onAppear { syncTimingText() }
        .onChange(of: cue.startMilliseconds) { syncTimingText() }
        .onChange(of: cue.endMilliseconds) { syncTimingText() }
        .onChange(of: timingFocus) { old, new in
            if old != nil, new == nil {
                commitTiming()
            }
        }
        .onChange(of: focusedCue) { old, new in
            if old == cue.ordinal,
               new != cue.ordinal,
               editingOrdinal == cue.ordinal {
                onCommitText()
            }
        }
    }

    @ViewBuilder
    private var textSection: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                TextField(
                    "Cue text",
                    text: $draftText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(
                    .system(
                        size: AppTheme.Reading.bodySize,
                        design: .serif
                    )
                )
                .lineSpacing(AppTheme.Reading.bodyLineSpacing)
                .lineLimit(1...8)
                .focused($focusedCue, equals: cue.ordinal)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else {
                        return .ignored
                    }
                    onCommitText()
                    return .handled
                }

                HStack(spacing: AppTheme.Spacing.xs) {
                    Text("⌘↩ to save")
                        .font(.system(size: AppTheme.TypeScale.xxs))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: AppTheme.Spacing.xxs)
                    BarIconButton(
                        systemName: "checkmark",
                        help: "Save cue text"
                    ) {
                        onCommitText()
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(
                RoundedRectangle(
                    cornerRadius: AppTheme.Radius.control,
                    style: .continuous
                )
                .fill(Color.appCanvas)
            )
        } else {
            Button {
                guard canEdit else { return }
                onSelect()
                onBeginEditing()
            } label: {
                Text(displayText.isEmpty ? "Empty cue" : displayText)
                    .font(
                        .system(
                            size: AppTheme.Reading.bodySize,
                            design: .serif
                        )
                    )
                    .lineSpacing(AppTheme.Reading.bodyLineSpacing)
                    .foregroundStyle(
                        displayText.isEmpty ? Color.secondary : Color.primary
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(canEdit ? "Edit cue text" : "Fix parsing errors in Source")
        }
    }

    private var metadataRow: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            timingField(
                title: "Start time",
                text: $startText,
                field: .start
            )

            Image(systemName: "arrow.right")
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(.quaternary)

            timingField(
                title: "End time",
                text: $endText,
                field: .end
            )

            Text(SubtitleTimecode.displayShort(cue.durationMilliseconds))
                .font(
                    .system(
                        size: AppTheme.TypeScale.xxs,
                        design: .monospaced
                    )
                )
                .foregroundStyle(.tertiary)

            if let warning = warnings.first {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(AppTheme.Palette.warning)
                    .help(warnings.map(\.message).joined(separator: "\n"))
            }
        }
    }

    private func timingField(
        title: String,
        text: Binding<String>,
        field: TimingField
    ) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .font(
                .system(
                    size: AppTheme.TypeScale.xs,
                    weight: .medium,
                    design: .monospaced
                )
            )
            .foregroundStyle(.secondary)
            .frame(width: AppTheme.Subtitle.cueTimeFieldWidth)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(
                RoundedRectangle(
                    cornerRadius: AppTheme.Radius.micro,
                    style: .continuous
                )
                .fill(Color.primary.opacity(AppTheme.Opacity.subtle))
            )
            .focused($timingFocus, equals: field)
            .onSubmit { commitTiming() }
            .disabled(!canEdit)
            .accessibilityLabel(title)
    }

    private var cueIsPlaying: Bool {
        isActive && workspace.player.isPlaying
    }

    private var canPlayCue: Bool {
        guard workspace.player.isReady else { return false }
        let duration = workspace.player.durationMilliseconds
        return duration <= 0 || cue.startMilliseconds < duration
    }

    private var playHelp: String {
        if cueIsPlaying { return "Pause" }
        if !workspace.player.isReady { return "Open media to preview" }
        if !canPlayCue { return "This cue starts after the media ends" }
        return "Play from this cue"
    }

    private var playButton: some View {
        Button {
            if cueIsPlaying {
                workspace.player.pause()
            } else {
                workspace.player.seek(
                    toMilliseconds: cue.startMilliseconds
                )
                workspace.player.play()
            }
        } label: {
            Image(systemName: cueIsPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
                .foregroundStyle(
                    cueIsPlaying ? Color.accentColor : Color.secondary
                )
                .frame(
                    width: AppTheme.ControlSize.medium,
                    height: AppTheme.ControlSize.regular
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canPlayCue)
        .help(playHelp)
        .accessibilityLabel(playHelp)
    }

    // MARK: - Editing

    private func syncTimingText() {
        if timingFocus != .start {
            startText = SubtitleTimecode.format(
                milliseconds: cue.startMilliseconds,
                format: document.format
            )
        }
        if timingFocus != .end {
            endText = SubtitleTimecode.format(
                milliseconds: cue.endMilliseconds,
                format: document.format
            )
        }
    }

    private func commitTiming() {
        guard canEdit else {
            syncTimingText()
            return
        }
        guard let start = SubtitleTimecode.parseUserInput(startText),
              let end = SubtitleTimecode.parseUserInput(endText) else {
            timingError = "Use HH:MM:SS.mmm or seconds."
            return
        }
        guard end > start else {
            timingError = "The end must come after the start."
            return
        }
        timingError = nil
        if start == cue.startMilliseconds, end == cue.endMilliseconds {
            syncTimingText()
            return
        }
        Task {
            _ = await workspace.apply(
                .setTiming(
                    ordinal: cue.ordinal,
                    startMilliseconds: start,
                    endMilliseconds: end
                ),
                to: document
            )
        }
    }
}
