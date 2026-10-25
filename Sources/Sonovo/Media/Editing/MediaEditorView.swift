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
            operationRow
            actionRow
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

    private var operationRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button("Set In") { onSetIn() }
                .disabled(document.editState == nil || isBusy)
            Button("Set Out") { onSetOut() }
                .disabled(document.editState == nil || isBusy)
            Button("Trim to Selection") { onTrim() }
                .disabled(!document.canTrimToSelection || isBusy)
            Button("Delete Selection") { onDelete() }
                .disabled(!document.canDeleteSelection || isBusy)
            Button("Clear Selection") { onClearSelection() }
                .disabled(document.selection == nil || isBusy)
            Button("Reset") { onReset() }
                .disabled(!document.canReset || isBusy)

            Spacer(minLength: AppTheme.Spacing.sm)

            Button("Undo") { onUndo() }
                .disabled(!document.canUndo || isBusy)
            Button("Redo") { onRedo() }
                .disabled(!document.canRedo || isBusy)
        }
        .font(.system(size: AppTheme.TypeScale.sm))
        .controlSize(.small)
    }

    private var actionRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if recorder.isRecording {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(AppTheme.Palette.warning)
                Text("Recording \(MediaTimecodeFormatter.elapsed(recorder.elapsed))")
                    .font(.system(size: AppTheme.TypeScale.xs, design: .monospaced))
                ProgressView(value: recorder.level)
                    .frame(width: AppTheme.Size.mediaRecordLevelWidth)
                Button("Stop Recording") {
                    _ = project.stopAudioRecording()
                }
            } else {
                Button("Record Audio") {
                    Task { _ = await project.startAudioRecording() }
                }
                .disabled(!project.canRecordAudio || isBusy)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            if let progress = exporter.progress {
                ProgressView(value: progress)
                    .frame(width: AppTheme.Size.mediaRecordLevelWidth)
                Text("\(Int(progress * 100))%") // token-exempt: percent readout
                    .font(.system(size: AppTheme.TypeScale.xxs, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Cancel") { exporter.cancel() }
            } else if isBusy {
                ProgressView()
                    .controlSize(.small)
                if exporter.isBusy {
                    Button("Cancel") { exporter.cancel() }
                }
            }

            Button("Save Take") { onSaveTake() }
                .disabled(!document.canExport || isBusy)
            Button("Replace Original…") { onReplace() }
                .disabled(!document.canReplaceOriginal || isBusy)
        }
        .font(.system(size: AppTheme.TypeScale.sm))
        .controlSize(.small)
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
