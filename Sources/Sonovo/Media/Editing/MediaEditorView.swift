import AppKit
import SwiftUI

/// Edit controls live beside the player. They are deliberately a small,
/// explicit set: selection, trim/delete, undo, record, save a take, replace
/// the source. A multitrack timeline does not belong here.
struct MediaEditorToolbar: View {
    let project: Project
    let document: MediaEditDocument
    let sourcePlayhead: Double
    let onSetIn: () -> Void
    let onSetOut: () -> Void
    let onClearSelection: () -> Void
    let onTrim: () -> Void
    let onDelete: () -> Void
    let onReset: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onSaveTake: () -> Void
    let onReplace: () -> Void

    private var recorder: AudioRecorder { project.mediaEdits.recorder }
    private var exporter: MediaExportService { project.mediaEdits.exportService }
    private var isBusy: Bool { project.mediaEdits.isExportingOperation }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            statusRow
            controlRow
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(Color.appCard)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.appSeparator)
                .frame(height: AppTheme.BorderWidth.hairline)
        }
    }

    private var statusRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(
                "Edited \(MediaTimecodeFormatter.elapsed(document.editedDuration))"
            )
            .font(.system(size: AppTheme.TypeScale.xs, design: .monospaced))
            .foregroundStyle(.secondary)

            Text(
                "Source \(MediaTimecodeFormatter.elapsed(document.sourceDuration))"
            )
            .font(.system(size: AppTheme.TypeScale.xs, design: .monospaced))
            .foregroundStyle(.tertiary)

            if let selection = document.selection {
                Text(
                    "Selection \(MediaTimecodeFormatter.elapsed(selection.start)) – \(MediaTimecodeFormatter.elapsed(selection.end))"
                )
                .font(
                    .system(
                        size: AppTheme.TypeScale.xs,
                        design: .monospaced
                    )
                )
                .foregroundStyle(.secondary)
            } else {
                Text("Drag the timeline to select")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            Text(
                "Playhead \(MediaTimecodeFormatter.elapsed(sourcePlayhead))"
            )
            .font(.system(size: AppTheme.TypeScale.xs, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
    }

    /// Icon-only controls keep the waveform dominant. Every control carries a
    /// tooltip, and the destructive replace action keeps a warning tint.
    private var controlRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            mediaButton(
                "rectangle.leadinghalf.inset.filled",
                help: "Set In",
                isEnabled: document.editState != nil && !isBusy
            ) {
                onSetIn()
            }

            mediaButton(
                "rectangle.trailinghalf.inset.filled",
                help: "Set Out",
                isEnabled: document.editState != nil && !isBusy
            ) {
                onSetOut()
            }

            controlDivider

            mediaButton(
                "crop",
                help: "Trim to Selection",
                isEnabled: document.canTrimToSelection && !isBusy
            ) {
                onTrim()
            }

            mediaButton(
                "trash",
                help: "Delete Selection",
                isEnabled: document.canDeleteSelection && !isBusy
            ) {
                onDelete()
            }

            mediaButton(
                "xmark.circle",
                help: "Clear Selection",
                isEnabled: document.selection != nil && !isBusy
            ) {
                onClearSelection()
            }

            mediaButton(
                "arrow.counterclockwise",
                help: "Reset Edit",
                isEnabled: document.canReset && !isBusy
            ) {
                onReset()
            }

            controlDivider

            mediaButton(
                "arrow.uturn.backward",
                help: "Undo Media Edit",
                isEnabled: document.canUndo && !isBusy
            ) {
                onUndo()
            }

            mediaButton(
                "arrow.uturn.forward",
                help: "Redo Media Edit",
                isEnabled: document.canRedo && !isBusy
            ) {
                onRedo()
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            recordingControls
            exportControls

            mediaButton(
                "square.and.arrow.down",
                help: "Save Take",
                isEnabled: document.canExport && !isBusy
            ) {
                onSaveTake()
            }

            mediaButton(
                "arrow.triangle.2.circlepath",
                help: "Replace Original…",
                tint: AppTheme.Palette.warning,
                isEnabled: document.canReplaceOriginal && !isBusy
            ) {
                onReplace()
            }
        }
    }

    @ViewBuilder
    private var recordingControls: some View {
        if recorder.isRecording {
            Image(systemName: "record.circle.fill")
                .font(
                    .system(
                        size: AppTheme.IconSize.medium,
                        weight: .medium
                    )
                )
                .foregroundStyle(AppTheme.Palette.warning)
                .frame(
                    width: AppTheme.ControlSize.large,
                    height: AppTheme.ControlSize.medium
                )
                .help("Recording in progress")
                .accessibilityLabel("Recording in progress")

            Text(MediaTimecodeFormatter.elapsed(recorder.elapsed))
                .font(.system(size: AppTheme.TypeScale.xs, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            ProgressView(value: recorder.level)
                .frame(width: AppTheme.Size.mediaRecordLevelWidth)
                .controlSize(.small)
                .accessibilityLabel("Input level")

            mediaButton(
                "stop.circle.fill",
                help: "Stop Recording",
                tint: AppTheme.Palette.warning
            ) {
                _ = project.stopAudioRecording()
            }
        } else {
            mediaButton(
                "record.circle",
                help: "Record Audio",
                tint: AppTheme.Palette.warning,
                isEnabled: project.canRecordAudio && !isBusy
            ) {
                Task { _ = await project.startAudioRecording() }
            }
        }
    }

    @ViewBuilder
    private var exportControls: some View {
        if let progress = exporter.progress {
            ProgressView(value: progress)
                .frame(width: AppTheme.Size.mediaRecordLevelWidth)
                .controlSize(.small)
                .accessibilityLabel("Export progress")

            Text("\(Int(progress * 100))%") // token-exempt: percent readout
                .font(.system(size: AppTheme.TypeScale.xxs, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            mediaButton("xmark", help: "Cancel Export") {
                exporter.cancel()
            }
        } else if isBusy {
            ProgressView()
                .controlSize(.small)
            if exporter.isBusy {
                mediaButton("xmark", help: "Cancel Export") {
                    exporter.cancel()
                }
            }
        }
    }

    private func mediaButton(
        _ systemName: String,
        help: String,
        tint: Color? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        BarIconButton(
            systemName: systemName,
            help: help,
            tint: tint,
            iconSize: AppTheme.IconSize.medium,
            width: AppTheme.ControlSize.large,
            height: AppTheme.ControlSize.medium,
            hasRestingBackground: true,
            isEnabled: isEnabled,
            action: action
        )
    }

    private var controlDivider: some View {
        Divider()
            .frame(height: AppTheme.Size.toolbarDividerHeight)
    }
}

struct MediaEditorNotices: View {
    let project: Project
    let document: MediaEditDocument
    let operationError: String?

    private var recorder: AudioRecorder { project.mediaEdits.recorder }
    private var exporter: MediaExportService { project.mediaEdits.exportService }

    var body: some View {
        let exportMessage: String? = {
            if case let .failed(message) = exporter.status { return message }
            return nil
        }()
        let message = operationError ?? project.mediaError
            ?? recorder.lastError ?? exportMessage
        let permissionMessage = AudioRecordingError.permissionDenied
            .localizedDescription
        let visibleMessage = recorder.permission.isDenied
            && message == permissionMessage
            ? nil
            : message

        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            if recorder.permission.isDenied {
                noticeRow(
                    icon: "mic.slash",
                    text: "Microphone access is denied.",
                    actionTitle: "Open Settings",
                    action: openMicrophoneSettings
                )
            }
            if let visibleMessage, !visibleMessage.isEmpty {
                Label(visibleMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(AppTheme.Palette.warning)
                    .lineLimit(3)
            }
            if document.hasPendingEdits {
                Label(
                    "This edit is not saved until you use Save Take.",
                    systemImage: "info.circle"
                )
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: AppTheme.Size.mediaStatusMaxWidth, alignment: .leading)
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.bottom, AppTheme.Spacing.sm)
    }

    private func noticeRow(
        icon: String,
        text: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Label(text, systemImage: icon)
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
            Spacer(minLength: AppTheme.Spacing.sm)
            Button(actionTitle, action: action)
                .controlSize(.small)
        }
    }

    private func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
