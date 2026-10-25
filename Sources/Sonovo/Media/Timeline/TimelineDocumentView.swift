import AppKit
import CoreMedia
import Foundation
import SonovoCore
import SwiftUI
import UniformTypeIdentifiers

/// B2's project timeline surface. The ruler, tracks, clips, and playhead all
/// read the same document; drag and trim commit one undoable edit.
struct TimelineDocumentView: View {
    let workspace: TimelineWorkspace
    let assets: [ProjectAsset]
    let selectedAsset: ProjectAsset?
    let project: Project

    @State private var selectedClipID: String?
    @State private var playhead = CMTime.zero
    @State private var pixelsPerSecond = AppTheme.Size.timelinePixelsPerSecond
    @State private var editError: String?
    @State private var dragClipID: String?
    @State private var dragOrigin = CMTime.zero
    @State private var dragDelta: CGFloat = AppTheme.Spacing.zero
    @State private var scrollOffset: CGFloat = AppTheme.Spacing.zero
    @State private var playback = MediaPlaybackModel()
    @State private var previewTask: Task<Void, Never>?
    @State private var peak: Float?

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
        .onAppear {
            rebuildPreview()
        }
        .onChange(of: currentTimeline) {
            rebuildPreview()
        }
        .onChange(of: playback.elapsed) { _, seconds in
            if playback.isPlaying {
                playhead = time(seconds)
            }
        }
        .onDisappear {
            previewTask?.cancel()
            playback.pause()
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
                exportTimeline()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Export the timeline as a new movie")
            .disabled(
                workspace.isExporting
                    || currentTimeline?.allClips.isEmpty != false
                    || project.isDemo
            )

            if workspace.isExporting {
                Button("Cancel") {
                    workspace.cancelExport()
                }
                .help("Cancel the timeline export")
            }

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

            if let peak {
                Text(
                    peak > 1
                        ? "Peak over 0 dBFS"
                        : String(
                            format: "Peak %.1f dBFS",
                            TimelineAudioPeak.decibels(peak)
                        )
                )
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(
                    peak > 1
                        ? AppTheme.Palette.error
                        : AppTheme.Palette.secondaryLabel
                )
            }

            if workspace.isExporting {
                Text(
                    "Exporting \(Int(workspace.exportProgress * AppTheme.Size.timelinePercentScale))%"
                )
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
            } else if let exportMessage = workspace.exportMessage {
                Text(exportMessage)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
            }

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
        VStack(spacing: AppTheme.Spacing.zero) {
            let issues = timeline.sourceIssues(assets: assets)
            if !issues.isEmpty {
                sourceIssues(issues)
            }
            if !timeline.videoTrack.clips.isEmpty {
                previewPane
            }
            GeometryReader { proxy in
                let seconds = max(
                    timeline.duration.seconds,
                    AppTheme.Size.timelineMinimumSeconds
                )
                let laneWidth = CGFloat(seconds) * pixelsPerSecond
                let contentWidth = AppTheme.Size.metadataLabelWidth + laneWidth
                let maxOffset = max(contentWidth - proxy.size.width, 0)
                let trackHeight = AppTheme.Size.timelineRulerHeight
                    + AppTheme.Size.timelineTrackHeight
                    * CGFloat(TimelineTrackKind.allCases.count)
                VStack(spacing: AppTheme.Spacing.zero) {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: AppTheme.Spacing.zero) {
                            ruler(seconds: seconds, laneWidth: laneWidth)
                            ForEach(
                                TimelineTrackKind.allCases,
                                id: \.self
                            ) { kind in
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
                                height: trackHeight
                            )
                            .offset(
                                x: AppTheme.Size.metadataLabelWidth
                                    + CGFloat(playhead.seconds) * pixelsPerSecond
                            )
                            .allowsHitTesting(false)
                    }
                    .frame(
                        width: contentWidth,
                        height: trackHeight,
                        alignment: .topLeading
                    )
                    .offset(x: -scrollOffset)
                    .frame(
                        width: proxy.size.width,
                        height: trackHeight,
                        alignment: .topLeading
                    )
                    .clipped()
                    if maxOffset > 0 {
                        Slider(value: $scrollOffset, in: 0...maxOffset)
                            .help("Scroll the timeline")
                            .padding(.horizontal, AppTheme.Spacing.md)
                            .padding(.vertical, AppTheme.Spacing.xs)
                    }
                }
                .onChange(of: maxOffset) { _, value in
                    scrollOffset = min(scrollOffset, value)
                }
            }
        }
    }

    private func sourceIssues(
        _ issues: [TimelineSourceIssue]
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Source problems block preview and export")
                .font(.system(size: AppTheme.TypeScale.sm, weight: .semibold))
                .foregroundStyle(AppTheme.Palette.warning)
            ForEach(issues) { issue in
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(issue.message)
                        .font(.system(size: AppTheme.TypeScale.xs))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Relink…") {
                        relink(issue)
                    }
                    .font(.system(size: AppTheme.TypeScale.xs))
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Palette.card)
    }

    private var previewPane: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            MediaPlayerView(player: playback.player)
                .frame(height: AppTheme.Size.timelinePreviewHeight)
                .background(AppTheme.Palette.black)
            HStack(spacing: AppTheme.Spacing.sm) {
                Button {
                    playback.togglePlayback()
                } label: {
                    Image(
                        systemName: playback.isPlaying
                            ? "pause.fill"
                            : "play.fill"
                    )
                }
                .buttonStyle(.plain)
                Text(
                    "\(timeLabel(playback.elapsed))"
                        + " / \(timeLabel(playback.duration))"
                )
                .font(.system(size: AppTheme.TypeScale.xs))
                .monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(AppTheme.Palette.card)
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
                        seek(to: value.location.x / pixelsPerSecond)
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
                                seek(
                                    to: value.location.x / pixelsPerSecond
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
            .contentShape(Rectangle())
            .offset(x: offset, y: AppTheme.Spacing.s10)
            .onTapGesture {
                selectedClipID = clip.id
                seek(to: clip.timelineStart.seconds)
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
            .highPriorityGesture(
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

    private func relink(_ issue: TimelineSourceIssue) {
        guard let root = project.root, let document else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.allowedContentTypes = issue.track == .video
            ? [.movie, .video]
            : [.audio]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        Task { @MainActor in
            await project.refreshNow()
            guard MarkdownSecurity.canonical(url).path
                    .hasPrefix(MarkdownSecurity.canonical(root).path),
                  let asset = project.assets.first(where: {
                      MarkdownSecurity.canonical($0.url)
                          == MarkdownSecurity.canonical(url)
                  }) else {
                editError = "Choose a media file inside this project."
                return
            }
            do {
                let duration = try await TimelineAssetProbe.duration(for: asset)
                try document.mutate { timeline in
                    try timeline.relink(
                        clipID: issue.clipID,
                        to: asset,
                        sourceDuration: duration
                    )
                }
                editError = nil
            } catch {
                editError = error.localizedDescription
            }
        }
    }

    private func addSelectedAsset(to kind: TimelineTrackKind) {
        guard let selectedAsset else { return }
        add(asset: selectedAsset, to: kind, at: playhead)
    }

    private func seek(to seconds: Double) {
        let clamped = max(seconds, 0)
        playhead = time(clamped)
        Task { @MainActor in
            await playback.seek(to: clamped)
        }
    }

    private func rebuildPreview() {
        previewTask?.cancel()
        playback.pause()
        guard let document,
              let timeline = document.timeline else {
            return
        }
        let url = document.url
        let assets = assets
        previewTask = Task { @MainActor in
            do {
                let built = try await ProjectTimelineCompositionBuilder.build(
                    timeline: timeline,
                    assets: assets
                )
                try Task.checkCancellation()
                playback.load(
                    asset: built.composition,
                    sourceURL: url,
                    fileSize: 0,
                    audioMix: built.audioMix,
                    videoComposition: built.videoComposition
                )
                peak = try await TimelineAudioPeak.measure(
                    asset: built.composition,
                    audioMix: built.audioMix
                )
                editError = nil
            } catch is CancellationError {
                // A newer edit owns the preview.
            } catch {
                editError = error.localizedDescription
            }
        }
    }

    private func exportTimeline() {
        guard let document,
              let timeline = document.timeline,
              let root = project.root else {
            return
        }
        editError = nil
        Task { @MainActor in
            do {
                let result = try await workspace.exportTimeline(
                    timeline: timeline,
                    assets: assets,
                    destinationDirectory: root
                )
                try Task.checkCancellation()
                await project.refreshNow()
                if let asset = project.assets.first(where: {
                    MarkdownSecurity.canonical($0.url)
                        == MarkdownSecurity.canonical(result.url)
                }) {
                    project.openAsset(asset)
                }
            } catch is CancellationError {
                // The workspace already shows the cancelled state.
            } catch {
                editError = error.localizedDescription
            }
        }
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
