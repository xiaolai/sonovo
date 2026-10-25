import CoreMedia
import Foundation
import SwiftUI

/// B2's project timeline surface. The ruler, tracks, clips, and playhead all
/// read the same document; drag and trim commit one undoable edit.
struct TimelineDocumentView: View {
    let workspace: TimelineWorkspace
    let assets: [ProjectAsset]
    let selectedAsset: ProjectAsset?

    @State private var selectedClipID: String?
    @State private var playhead = CMTime.zero
    @State private var pixelsPerSecond = AppTheme.Size.timelinePixelsPerSecond
    @State private var editError: String?
    @State private var dragClipID: String?
    @State private var dragOrigin = CMTime.zero
    @State private var dragDelta: CGFloat = AppTheme.Spacing.zero

    private var document: TimelineDocument? { workspace.document }

    private var currentTimeline: ProjectTimeline? {
        document?.timeline
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            toolbar
            Divider()
            if let timeline = currentTimeline {
                timelineContent(timeline)
            } else {
                errorContent(
                    workspace.lastError
                        ?? document?.errorMessage
                        ?? "No timeline is open."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDeleteCommand {
            deleteSelected()
        }
    }

    private var toolbar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button {
                workspace.save()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Save timeline")
            .disabled(document?.hasUnsavedChanges != true)

            Button {
                _ = document?.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("Undo")
            .disabled(document?.canUndo != true)

            Button {
                _ = document?.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .help("Redo")
            .disabled(document?.canRedo != true)

            Divider()
                .frame(height: AppTheme.Size.toolbarDividerHeight)

            Button {
                splitSelected()
            } label: {
                Image(systemName: "scissors")
            }
            .help("Split the selected clip at the playhead")
            .disabled(selectedClipID == nil)

            Button {
                deleteSelected()
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete the selected clip")
            .disabled(selectedClipID == nil)

            addMenu

            Divider()
                .frame(height: AppTheme.Size.toolbarDividerHeight)

            Button {
                zoom(by: 1 / AppTheme.Size.timelineZoomFactor)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")
            Button {
                zoom(by: AppTheme.Size.timelineZoomFactor)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")

            Spacer()

            if let editError {
                Text(editError)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(AppTheme.Palette.error)
            } else {
                statusLabel
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let document {
            switch document.status {
            case .idle:
                if document.hasUnsavedChanges {
                    Text("Unsaved")
                        .foregroundStyle(.secondary)
                }
            case .loading:
                Text("Loading…")
                    .foregroundStyle(.secondary)
            case .saving:
                Text("Saving…")
                    .foregroundStyle(.secondary)
            case .saved:
                Text("Saved")
                    .foregroundStyle(.secondary)
            case let .failed(message):
                Text(message)
                    .foregroundStyle(AppTheme.Palette.error)
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Voice Track") {
                addSelectedAsset(to: .voice)
            }
            Button("Music Track") {
                addSelectedAsset(to: .music)
            }
            Button("Video Track") {
                addSelectedAsset(to: .video)
            }
        } label: {
            Image(systemName: "plus.rectangle.on.rectangle")
        }
        .help("Add the selected project asset at the playhead")
        .disabled(selectedAsset == nil)
    }

    private func timelineContent(_ timeline: ProjectTimeline) -> some View {
        GeometryReader { proxy in
            let seconds = max(
                timeline.duration.seconds,
                AppTheme.Size.timelineMinimumSeconds
            )
            let laneWidth = CGFloat(seconds) * pixelsPerSecond
            let contentWidth = AppTheme.Size.metadataLabelWidth + laneWidth
            ScrollView([.horizontal]) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: AppTheme.Spacing.zero) {
                        ruler(seconds: seconds, laneWidth: laneWidth)
                        ForEach(TimelineTrackKind.allCases, id: \.self) { kind in
                            trackRow(
                                kind: kind,
                                clips: timeline.clips(for: kind),
                                laneWidth: laneWidth
                            )
                        }
                    }
                    Rectangle()
                        .fill(AppTheme.Palette.selection)
                        .frame(
                            width: AppTheme.Size.timelinePlayheadWidth,
                            height: AppTheme.Size.timelineRulerHeight
                                + AppTheme.Size.timelineTrackHeight
                                * CGFloat(TimelineTrackKind.allCases.count)
                        )
                        .offset(
                            x: AppTheme.Size.metadataLabelWidth
                                + CGFloat(playhead.seconds) * pixelsPerSecond
                        )
                        .allowsHitTesting(false)
                }
                .frame(
                    width: max(contentWidth, proxy.size.width),
                    alignment: .leading
                )
            }
        }
    }

    private func ruler(seconds: Double, laneWidth: CGFloat) -> some View {
        HStack(spacing: AppTheme.Spacing.zero) {
            Color.clear
                .frame(width: AppTheme.Size.metadataLabelWidth)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(AppTheme.Palette.card)
                // token-exempt: one-second ruler steps are content spacing
                let steps = Int(ceil(seconds / AppTheme.Size.timelineRulerStepSeconds))
                ForEach(0...steps, id: \.self) { step in
                    let value = Double(step)
                        * AppTheme.Size.timelineRulerStepSeconds
                    Text(timeLabel(value))
                        .font(.system(size: AppTheme.TypeScale.xxs))
                        .foregroundStyle(.secondary)
                        .offset(
                            x: CGFloat(step)
                                * CGFloat(AppTheme.Size.timelineRulerStepSeconds)
                                * pixelsPerSecond
                                + AppTheme.Spacing.xs
                        )
                }
            }
            .frame(width: laneWidth, height: AppTheme.Size.timelineRulerHeight)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        playhead = time(value.location.x / pixelsPerSecond)
                    }
            )
        }
        .frame(height: AppTheme.Size.timelineRulerHeight)
    }

    private func trackRow(
        kind: TimelineTrackKind,
        clips: [TimelineClip],
        laneWidth: CGFloat
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.zero) {
            Text(kind.displayName)
                .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(
                    width: AppTheme.Size.metadataLabelWidth,
                    alignment: .leading
                )
                .padding(.leading, AppTheme.Spacing.sm)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(AppTheme.Palette.card)
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                selectedClipID = nil
                                playhead = time(
                                    value.location.x / pixelsPerSecond
                                )
                            }
                    )
                ForEach(clips) { clip in
                    clipView(clip, kind: kind)
                }
            }
            .frame(width: laneWidth, height: AppTheme.Size.timelineTrackHeight)
            .dropDestination(for: String.self) { identifiers, location in
                guard let identifier = identifiers.first,
                      let asset = assets.first(
                          where: { $0.id == identifier }
                      ) else {
                    return false
                }
                add(
                    asset: asset,
                    to: kind,
                    at: time(location.x / pixelsPerSecond)
                )
                return true
            }
        }
        .frame(height: AppTheme.Size.timelineTrackHeight)
    }

    private func clipView(
        _ clip: TimelineClip,
        kind: TimelineTrackKind
    ) -> some View {
        let width = max(
            CGFloat(clip.sourceDuration.seconds) * pixelsPerSecond,
            AppTheme.Size.timelineClipMinWidth
        )
        let isSelected = selectedClipID == clip.id
        let offset = isSelected && dragClipID == clip.id
            ? CGFloat(dragOrigin.seconds) * pixelsPerSecond + dragDelta
            : CGFloat(clip.timelineStart.seconds) * pixelsPerSecond
        return RoundedRectangle(cornerRadius: AppTheme.Radius.control)
            .fill(
                isSelected
                    ? AppTheme.Palette.selection.opacity(AppTheme.Opacity.tint)
                    : AppTheme.Palette.cueTracks[
                        TimelineTrackKind.allCases.firstIndex(of: kind) ?? 0
                    ].opacity(AppTheme.Opacity.faint)
            )
            .overlay(alignment: .leading) {
                Text(clip.relativePath)
                    .font(.system(size: AppTheme.TypeScale.xxs, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, AppTheme.Spacing.xs)
            }
            .overlay(alignment: .leading) {
                trimHandle(clip: clip, leading: true)
            }
            .overlay(alignment: .trailing) {
                trimHandle(clip: clip, leading: false)
            }
            .frame(
                width: width,
                height: AppTheme.Size.timelineClipHeight
            )
            .offset(x: offset, y: AppTheme.Spacing.s10)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedClipID = clip.id
                playhead = clip.timelineStart.cmTime
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragClipID != clip.id {
                            dragClipID = clip.id
                            dragOrigin = clip.timelineStart.cmTime
                        }
                        dragDelta = value.translation.width
                    }
                    .onEnded { value in
                        let proposed = dragOrigin
                            + seconds(value.translation.width / pixelsPerSecond)
                        commitMove(clipID: clip.id, to: snapTime(proposed))
                        dragClipID = nil
                        dragOrigin = .zero
                        dragDelta = AppTheme.Spacing.zero
                    }
            )
    }

    private func trimHandle(
        clip: TimelineClip,
        leading: Bool
    ) -> some View {
        Rectangle()
            .fill(AppTheme.Palette.selection)
            .frame(width: AppTheme.Size.timelineTrimHandleWidth)
            .opacity(
                selectedClipID == clip.id
                    ? AppTheme.Opacity.tint
                    : AppTheme.Opacity.zero
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onEnded { value in
                        let delta = seconds(
                            value.translation.width / pixelsPerSecond
                        )
                        let base = leading
                            ? clip.timelineStart.cmTime
                            : clip.timelineEnd
                        let target = snapTime(base + delta)
                        commitTrim(
                            clipID: clip.id,
                            leading: leading,
                            to: target
                        )
                    }
            )
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

    private func addSelectedAsset(to kind: TimelineTrackKind) {
        guard let selectedAsset else { return }
        add(asset: selectedAsset, to: kind, at: playhead)
    }

    private func add(
        asset: ProjectAsset,
        to kind: TimelineTrackKind,
        at start: CMTime
    ) {
        Task { @MainActor in
            do {
                let duration = try await TimelineAssetProbe.duration(for: asset)
                try document?.mutate { timeline in
                    try timeline.addClip(
                        asset: asset,
                        track: kind,
                        at: start,
                        duration: duration
                    )
                }
                editError = nil
            } catch {
                editError = error.localizedDescription
            }
        }
    }

    private func commitMove(clipID: String, to time: CMTime) {
        do {
            try document?.mutate { timeline in
                try timeline.moveClip(id: clipID, to: time)
            }
            editError = nil
        } catch {
            editError = error.localizedDescription
        }
    }

    private func commitTrim(
        clipID: String,
        leading: Bool,
        to time: CMTime
    ) {
        do {
            try document?.mutate { timeline in
                if leading {
                    try timeline.trimStart(id: clipID, to: time)
                } else {
                    try timeline.trimEnd(id: clipID, to: time)
                }
            }
            editError = nil
        } catch {
            editError = error.localizedDescription
        }
    }

    private func splitSelected() {
        guard let selectedClipID else { return }
        do {
            try document?.mutate { timeline in
                _ = try timeline.splitClip(
                    id: selectedClipID,
                    at: playhead
                )
            }
            editError = nil
        } catch {
            editError = error.localizedDescription
        }
    }

    private func deleteSelected() {
        guard let selectedClipID else { return }
        do {
            try document?.mutate { timeline in
                try timeline.deleteClip(id: selectedClipID)
            }
            self.selectedClipID = nil
            editError = nil
        } catch {
            editError = error.localizedDescription
        }
    }

    private func zoom(by factor: Double) {
        pixelsPerSecond = min(
            max(
                pixelsPerSecond * factor,
                AppTheme.Size.timelineMinimumPixelsPerSecond
            ),
            AppTheme.Size.timelineMaximumPixelsPerSecond
        )
    }

    private func snapTime(_ time: CMTime) -> CMTime {
        guard let timeline = currentTimeline else { return time }
        var candidates = timeline.allClips.flatMap {
            [$0.timelineStart.cmTime, $0.timelineEnd]
        }
        candidates.append(playhead)
        candidates.append(.zero)
        return timeline.snap(
            time,
            candidates: candidates,
            tolerance: seconds(AppTheme.Spacing.s10 / pixelsPerSecond)
        )
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(seconds, 0), preferredTimescale: 600_000)
    }

    private func seconds(_ pixels: CGFloat) -> CMTime {
        CMTime(
            seconds: Double(pixels) / pixelsPerSecond,
            preferredTimescale: 600_000
        )
    }

    private func timeLabel(_ seconds: Double) -> String {
        let whole = Int(max(seconds, 0))
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
