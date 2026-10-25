import CoreMedia
import Foundation
import SwiftUI

/// B1's timeline document surface: identity, save state, and the three
/// frozen tracks. B2 replaces the track list with the interactive workspace.
struct TimelineDocumentView: View {
    let workspace: TimelineWorkspace
    let assets: [ProjectAsset]

    var body: some View {
        Group {
            if let document = workspace.document,
               let timeline = document.timeline {
                content(document: document, timeline: timeline)
            } else if let message = workspace.lastError
                ?? workspace.document?.errorMessage {
                errorContent(message)
            } else {
                EmptyEditorView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(
        document: TimelineDocument,
        timeline: ProjectTimeline
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            header(document: document, timeline: timeline)
            Divider()
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                ForEach(timeline.tracks, id: \.0) { track in
                    trackRow(kind: track.0, clips: track.1)
                }
            }
            sourceIssues(timeline.sourceIssues(assets: assets))
            Spacer(minLength: AppTheme.Spacing.zero)
            footer(document: document)
        }
        .padding(AppTheme.Spacing.xl)
    }

    private func header(
        document: TimelineDocument,
        timeline: ProjectTimeline
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(timeline.name)
                    .font(.system(size: AppTheme.TypeScale.hero, weight: .semibold))
                Text(document.url.lastPathComponent)
                    .font(.system(size: AppTheme.TypeScale.sm))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Save") {
                workspace.save()
            }
            .disabled(!document.hasUnsavedChanges)
            Button("Undo") {
                _ = document.undo()
            }
            .disabled(!document.canUndo)
            Button("Redo") {
                _ = document.redo()
            }
            .disabled(!document.canRedo)
        }
    }

    private func trackRow(
        kind: TimelineTrackKind,
        clips: [TimelineClip]
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Text(kind.displayName)
                .font(.system(size: AppTheme.TypeScale.body, weight: .medium))
                .frame(
                    width: AppTheme.Size.metadataLabelWidth,
                    alignment: .leading
                )
            Text(clipSummary(clips))
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, AppTheme.Spacing.sm)
        .padding(.horizontal, AppTheme.Spacing.md)
        .background(
            AppTheme.Palette.card,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.panel)
        )
    }

    @ViewBuilder
    private func sourceIssues(_ issues: [TimelineSourceIssue]) -> some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Source problems")
                    .font(.system(size: AppTheme.TypeScale.body, weight: .semibold))
                ForEach(issues) { issue in
                    Text(issue.message)
                        .font(.system(size: AppTheme.TypeScale.sm))
                        .foregroundStyle(AppTheme.Palette.warning)
                }
            }
            .padding(AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AppTheme.Palette.card,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.panel)
            )
        }
    }

    private func footer(document: TimelineDocument) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            statusLabel(document: document)
            Spacer()
            if document.errorMessage != nil {
                Button("Reload") {
                    workspace.reload()
                }
            }
        }
        .font(.system(size: AppTheme.TypeScale.sm))
    }

    @ViewBuilder
    private func statusLabel(document: TimelineDocument) -> some View {
        switch document.status {
        case .idle:
            if document.hasUnsavedChanges {
                Text("Unsaved changes")
            }
        case .loading:
            Text("Loading…")
        case .saving:
            Text("Saving…")
        case .saved:
            Text("Saved")
        case let .failed(message):
            Text(message)
                .foregroundStyle(AppTheme.Palette.error)
        }
    }

    private func errorContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Timeline unavailable")
                .font(.system(size: AppTheme.TypeScale.title, weight: .semibold))
            Text(message)
                .font(.system(size: AppTheme.TypeScale.body))
                .foregroundStyle(.secondary)
            Button("Reload") {
                workspace.reload()
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func clipSummary(_ clips: [TimelineClip]) -> String {
        let count = clips.count
        if count == 0 {
            return "No clips"
        }
        let total = clips.reduce(CMTime.zero) { result, clip in
            result + clip.sourceDuration.cmTime
        }
        return "\(count) clip\(count == 1 ? "" : "s") · \(timeText(total))"
    }

    private func timeText(_ time: CMTime) -> String {
        let seconds = max(time.seconds, 0)
        let whole = Int(seconds)
        let minutes = whole / 60
        let remainder = whole % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}

extension TimelineTrackKind {
    var displayName: String {
        switch self {
        case .video: "Video"
        case .voice: "Voice"
        case .music: "Music"
        }
    }
}
