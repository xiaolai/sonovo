import AppKit
import SonovoCore
import SwiftUI

enum MediaAssetMode: String, CaseIterable, Identifiable, Sendable {
    case player
    case edit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .player: "Player"
        case .edit: "Edit"
        }
    }
}

/// One real audio or video file. Player mode reads the source file; Edit mode
/// previews the kept-range composition while the waveform keeps showing the
/// source timeline. The asset view owns the player so switching tabs releases
/// the decoder; the edit decision itself belongs to the project.
@MainActor
struct MediaAssetView: View {
    let asset: ProjectAsset
    var project: Project?
    var appState: AppState?

    private enum LoadedMedia: Equatable {
        case none
        case source
        case composition
    }

    @State private var playback = MediaPlaybackModel()
    @State private var waveform = WaveformModel()
    @State private var scrubValue: Double?
    @State private var mode: MediaAssetMode = .player
    @State private var editDocument: MediaEditDocument?
    @State private var loaded: LoadedMedia = .none
    @State private var pendingEditStart = false
    @State private var pendingReload = false
    @State private var previewGeneration: UInt64 = 0
    @State private var previewedRanges: [MediaTimeRange] = []
    /// The old player item stays current while a new composition builds. Keep
    /// audition and timeline mapping off the old item during that window.
    @State private var isPreviewPending = false
    @State private var operationError: String?
    @State private var showReplaceConfirmation = false
    @State private var isTimelineInteracting = false
    @State private var silenceCandidates: [MediaTimeRange] = []
    @State private var silenceSettings = MediaSilenceSettings()
    @State private var showSilencePopover = false
    @State private var transcriptVisible = false
    @State private var transcriptSession: TranscriptSession?
    @Environment(\.projectIsVisible) private var projectIsVisible
    @Environment(\.scenePhase) private var scenePhase

    private var failure: String? {
        switch playback.state {
        case .unsupported(let message), .failed(let message):
            message
        default:
            nil
        }
    }

    private var canEdit: Bool {
        guard project != nil else { return false }
        return asset.kind == .audio || asset.kind == .video
    }

    private var isExportingOperation: Bool {
        project?.mediaEdits.isExportingOperation ?? false
    }

    private var waveformMessage: String? {
        switch waveform.state {
        case let .failed(message), let .unavailable(message):
            message
        case .noAudio:
            "No audio track in this file."
        default:
            nil
        }
    }

    private var canAudition: Bool {
        guard !isExportingOperation,
              !isPreviewPending,
              playback.state == .ready,
              let state = editDocument?.editState,
              let selection = state.selection else {
            return false
        }
        return MediaAudition.range(for: selection, in: state) != nil
    }

    private var canFindPauses: Bool {
        guard !isExportingOperation,
              asset.kind == .audio,
              editDocument?.isStale != true,
              waveform.state == .ready,
              waveform.data != nil,
              let document = editDocument,
              document.editState?.keepRanges.isEmpty == false else {
            return false
        }
        return true
    }

    private var findPausesHelp: String {
        if asset.kind != .audio {
            return "Pause removal is available for audio files"
        }
        if isExportingOperation {
            return "Wait for the export to finish"
        }
        if waveform.state == .loading {
            return "The waveform is still loading"
        }
        if waveform.data == nil {
            return "No audio waveform is available"
        }
        return "Find Pauses…"
    }

    private var sourcePlayhead: Double {
        guard mode == .edit,
              let state = editDocument?.editState else {
            return playback.elapsed
        }
        guard !isPreviewPending else { return 0 }
        return state.sourceTime(forEditedTime: playback.elapsed)
    }

    private var showsVideoInEdit: Bool {
        playback.state == .ready ? playback.hasVideo : asset.kind == .video
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            header
            Divider()
            if mode == .edit {
                editContent
            } else {
                stage
            }
            if failure == nil {
                Divider()
                transport
            }
        }
        .background(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.surface,
                style: .continuous
            )
            .fill(Color.appText)
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.surface,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.surface,
                style: .continuous
            )
            .strokeBorder(
                Color.appSeparator,
                lineWidth: AppTheme.BorderWidth.hairline
            )
        )
        .padding(AppTheme.Spacing.lg)
        .task(id: asset.id) {
            loadSource()
        }
        .onChange(of: mode) { _, next in
            if next == .edit {
                enterEdit()
            } else {
                leaveEdit()
            }
        }
        .onChange(of: playback.state) { _, state in
            handlePlaybackState(state)
        }
        .onChange(of: playback.elapsed) { _, _ in
            followPlayhead()
        }
        .onChange(of: editDocument?.selection) { _, _ in
            playback.stopAudition()
        }
        .onChange(of: isExportingOperation) { _, busy in
            if busy {
                playback.stopAudition()
            }
        }
        .onChange(of: asset.revision) { _, _ in
            handleAssetRevisionChange()
        }
        .onChange(of: playback.hasAudio) { _, hasAudio in
            guard hasAudio, asset.kind == .audio else { return }
            waveform.load(url: asset.url, revision: asset.revision)
        }
        .onChange(of: editDocument?.editState?.keepRanges) { _, ranges in
            guard mode == .edit,
                  editDocument?.isStale != true,
                  let ranges,
                  ranges != previewedRanges else {
                return
            }
            playback.stopAudition()
            showSilencePopover = false
            silenceCandidates = []
            operationError = nil
            rebuildPreview()
        }
        .onChange(of: projectIsVisible) { _, visible in
            if !visible {
                playback.pause()
            } else {
                consumeReplaceRequest()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                project?.mediaEdits.recorder.refreshPermission()
            }
        }
        .onChange(of: appState?.mediaReplaceRequest) { _, _ in
            consumeReplaceRequest()
        }
        .onChange(of: showSilencePopover) { _, shown in
            if !shown {
                silenceCandidates = []
            }
        }
        .confirmationDialog(
            "Replace \(asset.name)?",
            isPresented: $showReplaceConfirmation,
            titleVisibility: .visible
        ) {
            Button("Replace Original", role: .destructive) {
                Task { await performExport(.replaceOriginal) }
            }
            .disabled(isExportingOperation || editDocument?.isStale == true)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The edited file replaces the source. A timestamped backup is kept outside the project first."
            )
        }
        .onDisappear {
            previewGeneration &+= 1
            isPreviewPending = false
            transcriptSession?.cancel()
            playback.stopAudition()
            playback.unload()
            waveform.cancel()
            if let project, let editDocument {
                project.mediaEdits.deactivate(editDocument)
            }
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: asset.kind.icon)
                .font(.system(size: AppTheme.TypeScale.body))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(asset.name)
                    .font(.system(size: AppTheme.TypeScale.md, weight: .semibold))
                    .lineLimit(1)
                Text(metadataLine)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            if canEdit {
                Picker("Mode", selection: $mode) {
                    ForEach(MediaAssetMode.allCases) { value in
                        Text(value.label).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: AppTheme.Size.mediaModePickerWidth)
            }

            Text(asset.fileExtension.uppercased())
                .font(.system(size: AppTheme.TypeScale.xxs, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: AppTheme.Layout.subtitleHeaderHeight)
    }

    private var metadataLine: String {
        var parts: [String] = []
        if let codec = playback.videoCodec { parts.append(codec) }
        if playback.hasVideo, playback.videoSize.width > 0 {
            let width = NumericConversion.int(playback.videoSize.width) ?? 0
            let height = NumericConversion.int(playback.videoSize.height) ?? 0
            parts.append("\(width)×\(height)")
        }
        if playback.nominalFrameRate > 0 {
            parts.append(
                String(format: "%.2f fps", playback.nominalFrameRate)
            )
        }
        if let audio = playback.audioSummary { parts.append(audio) }
        if parts.isEmpty {
            parts.append(asset.kind.projectGroup.title)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Player

    @ViewBuilder
    private var stage: some View {
        if let failure {
            failureState(failure)
        } else if playback.state == .ready {
            if playback.hasVideo {
                MediaPlayerView(player: playback.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.Palette.black)
            } else {
                audioStage
            }
        } else {
            loadingState
        }
    }

    private var audioStage: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            if let waveformMessage {
                Text(waveformMessage)
                    .font(.system(size: AppTheme.TypeScale.sm))
                    .foregroundStyle(.secondary)
            }
            MediaWaveformView(
                data: waveform.data,
                progress: playback.duration > 0
                    ? playback.elapsed / playback.duration
                    : 0
            ) { fraction in
                Task { @MainActor in
                    await playback.seek(
                        to: fraction * playback.duration
                    )
                }
            }
            .frame(height: AppTheme.Size.waveformHeight)

            if waveform.state == .loading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Edit

    @ViewBuilder
    private var editContent: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            if let project, let editDocument {
                MediaEditorNotices(
                    project: project,
                    document: editDocument,
                    operationError: operationError
                )
            }

            if let failure {
                failureState(failure)
            } else if editDocument?.isStale == true {
                staleState
            } else if let editDocument, let project {
                editStage(editDocument)
                MediaEditorToolbar(
                    project: project,
                    document: editDocument,
                    sourcePlayhead: sourcePlayhead,
                    onSetIn: {
                        setSelectionStart(editDocument)
                    },
                    onSetOut: {
                        setSelectionEnd(editDocument)
                    },
                    onClearSelection: {
                        _ = editDocument.clearSelection()
                    },
                    onTrim: {
                        applyEdit { editDocument.trimToSelection() }
                    },
                    onDelete: {
                        applyEdit { editDocument.deleteSelection() }
                    },
                    onReset: {
                        applyEdit { editDocument.reset() }
                    },
                    onUndo: {
                        applyEdit { editDocument.undo() }
                    },
                    onRedo: {
                        applyEdit { editDocument.redo() }
                    },
                    onSaveTake: {
                        Task { await performExport(.newTake) }
                    },
                    onReplace: {
                        showReplaceConfirmation = true
                    },
                    isAuditioning: playback.isAuditioning,
                    canAudition: canAudition,
                    onAudition: {
                        toggleAudition(document: editDocument)
                    },
                    canFindPauses: canFindPauses,
                    findPausesHelp: findPausesHelp,
                    onFindPauses: {
                        showSilencePopover.toggle()
                    },
                    isTranscriptVisible: transcriptVisible,
                    onToggleTranscript: {
                        toggleTranscript()
                    }
                )
                .popover(
                    isPresented: $showSilencePopover,
                    arrowEdge: .bottom
                ) {
                    MediaSilenceReview(
                        data: waveform.data,
                        sourceDuration: editDocument.sourceDuration,
                        keepRanges: editDocument.editState?.keepRanges ?? [],
                        selection: editDocument.selection,
                        settings: $silenceSettings,
                        onCandidates: { candidates in
                            silenceCandidates = candidates
                        },
                        onRemove: { ranges in
                            removeSilences(ranges, document: editDocument)
                        }
                    )
                }
            } else {
                loadingState
            }
        }
    }

    @ViewBuilder
    private func editStage(_ document: MediaEditDocument) -> some View {
        if document.editState?.keepRanges.isEmpty == true {
            ContentUnavailableView(
                "Everything Removed",
                systemImage: "scissors",
                description: Text("Reset the edit to bring the source back.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                let compact = geometry.size.height < 520
                HStack(spacing: AppTheme.Spacing.zero) {
                    VStack(spacing: AppTheme.Spacing.zero) {
                        if showsVideoInEdit {
                            if playback.state == .ready {
                                MediaPlayerView(player: playback.player)
                                    .frame(
                                        maxWidth: .infinity,
                                        maxHeight: .infinity
                                    )
                                    .background(AppTheme.Palette.black)
                            } else {
                                loadingState
                            }
                        } else {
                            Spacer(minLength: AppTheme.Spacing.zero)
                        }
                        timeline(document, compact: compact)
                            .padding(.horizontal, AppTheme.Spacing.md)
                            .padding(.vertical, AppTheme.Spacing.sm)
                            .background(Color.appCard)
                        if !showsVideoInEdit {
                            Spacer(minLength: AppTheme.Spacing.zero)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if transcriptVisible, let transcriptSession {
                        Divider()
                        MediaTranscriptView(
                            session: transcriptSession,
                            document: document,
                            playhead: sourcePlayhead,
                            onSeek: { sourceTime in
                                seekSource(sourceTime, document: document)
                            }
                        )
                        .frame(
                            width: AppTheme.Size.mediaTranscriptPaneWidth
                        )
                    }
                }
            }
        }
    }

    private func timeline(
        _ document: MediaEditDocument,
        compact: Bool
    ) -> some View {
        let busy = project?.mediaEdits.isExportingOperation ?? false
        let viewport = effectiveViewport(for: document)
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            if let waveformMessage {
                Text(waveformMessage)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
            }
            MediaTimelineView(
                data: waveform.data,
                sourceDuration: document.sourceDuration,
                removedRanges: document.editState?.removedRanges ?? [],
                selection: document.selection,
                playhead: sourcePlayhead,
                viewport: viewport,
                silenceCandidates: silenceCandidates,
                compact: compact,
                isInteractionEnabled: !busy && !isPreviewPending,
                thumbnailURL: showsVideoInEdit ? asset.url : nil,
                thumbnailRevision: showsVideoInEdit ? asset.revision : nil,
                showsThumbnails: showsVideoInEdit && !compact,
                thumbnailsEnabled: !busy && !playback.isPlaying,
                onSeek: { sourceTime in
                    guard !(project?.mediaEdits.isExportingOperation ?? false)
                    else { return }
                    seekSource(sourceTime, document: document)
                },
                onSelect: { start, end in
                    guard !(project?.mediaEdits.isExportingOperation ?? false)
                    else { return }
                    _ = document.setSelection(start: start, end: end)
                    operationError = nil
                },
                onNudge: { edge, delta in
                    guard !(project?.mediaEdits.isExportingOperation ?? false)
                    else { return }
                    switch edge {
                    case .start:
                        _ = document.nudgeSelectionStart(bySourceDelta: delta)
                    case .end:
                        _ = document.nudgeSelectionEnd(bySourceDelta: delta)
                    }
                },
                onViewportChange: { next in
                    document.timelineViewport = next.clamped(
                        to: document.sourceDuration
                    )
                },
                onInteractionChange: { interacting in
                    isTimelineInteracting = interacting
                }
            )
            if waveform.state == .loading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func effectiveViewport(
        for document: MediaEditDocument
    ) -> MediaTimelineViewport {
        (document.timelineViewport ?? .full(
            sourceDuration: document.sourceDuration
        )).clamped(to: document.sourceDuration)
    }

    private var staleState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(
                    .system(
                        size: AppTheme.TypeScale.displayLarge,
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(AppTheme.Palette.warning)
            Text("Source Changed")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))
            Text(
                "This file changed on disk. Reloading discards the current edit decision and starts from the new bytes."
            )
            .font(.system(size: AppTheme.TypeScale.sm))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: AppTheme.Layout.emptyDescriptionMaxWidth)
            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Reload Source") { reloadSource() }
                    .disabled(project?.mediaEdits.isExportingOperation == true)
                Button("Discard Edit", role: .destructive) {
                    discardEdit()
                }
                .disabled(project?.mediaEdits.isExportingOperation == true)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadSource() {
        loaded = .source
        playback.load(url: asset.url)
        if asset.kind == .audio {
            waveform.load(url: asset.url, revision: asset.revision)
        }
    }

    private func enterEdit() {
        guard let project else { return }
        playback.pause()
        operationError = nil
        silenceCandidates = []
        project.clearMediaError()
        let document = project.mediaEdits.document(for: asset)
        editDocument = document
        project.mediaEdits.activate(document)
        ensureTranscriptSession()
        if asset.kind == .video {
            waveform.load(url: asset.url, revision: asset.revision)
        }
        if document.isStale {
            pendingEditStart = false
            return
        }
        if loaded == .source, playback.state == .ready {
            if document.editState == nil {
                document.prepare(sourceDuration: playback.duration)
            } else {
                rebuildPreview()
            }
        } else {
            pendingEditStart = true
        }
    }

    private func leaveEdit() {
        playback.stopAudition()
        pendingEditStart = false
        pendingReload = false
        previewGeneration &+= 1
        isPreviewPending = false
        previewedRanges = []
        isTimelineInteracting = false
        silenceCandidates = []
        transcriptSession?.cancel()
        transcriptSession = nil
        if let project, let editDocument {
            project.mediaEdits.deactivate(editDocument)
        }
        editDocument = nil
        operationError = nil
        if loaded == .composition || playback.state == .idle {
            loadSource()
        }
    }

    private func followPlayhead() {
        guard mode == .edit,
              !isPreviewPending,
              playback.isPlaying,
              !isTimelineInteracting,
              let document = editDocument,
              document.sourceDuration > 0 else {
            return
        }
        let current = effectiveViewport(for: document)
        let next = current.followed(
            to: sourcePlayhead,
            sourceDuration: document.sourceDuration
        )
        if next != current {
            document.timelineViewport = next
        }
    }

    private func handlePlaybackState(_ state: MediaPlaybackModel.State) {
        guard state == .ready,
              mode == .edit,
              loaded == .source,
              let document = editDocument else {
            return
        }
        if pendingReload {
            pendingReload = false
            previewedRanges = []
            document.reload(sourceDuration: playback.duration)
            return
        }
        guard !document.isStale else { return }
        pendingEditStart = false
        if document.editState == nil {
            document.prepare(sourceDuration: playback.duration)
        } else {
            rebuildPreview()
        }
    }

    /// The view is keyed by asset id, not revision, so an external overwrite
    /// does not silently recreate the player. In player mode it reloads the
    /// new bytes; in edit mode it preserves the decision but marks it stale.
    private func handleAssetRevisionChange() {
        if mode == .edit {
            guard let project else { return }
            let document = project.mediaEdits.document(for: asset)
            editDocument = document
            transcriptSession?.cancel()
            transcriptSession = TranscriptSession(asset: asset)
            if transcriptVisible, let transcriptSession {
                Task { await transcriptSession.loadCached() }
            }
            if document.editState == nil {
                // A successful replace discards the old document; the
                // replaced source has no edit decision yet. Return to the
                // player and reload the new bytes: the player may still hold
                // the old source item under the same URL.
                project.mediaEdits.close(url: asset.url)
                loadSource()
                mode = .player
                return
            }
            if document.isStale {
                playback.pause()
                playback.unload()
                loaded = .none
                previewGeneration &+= 1
                isPreviewPending = false
                previewedRanges = []
            }
        } else {
            loadSource()
        }
    }

    private func reloadSource() {
        guard editDocument != nil else { return }
        playback.stopAudition()
        operationError = nil
        pendingReload = true
        pendingEditStart = false
        previewedRanges = []
        previewGeneration &+= 1
        isPreviewPending = false
        loaded = .source
        playback.load(url: asset.url)
        if asset.kind == .audio || asset.kind == .video {
            waveform.load(url: asset.url, revision: asset.revision)
        }
    }

    private func discardEdit() {
        guard let project else { return }
        project.mediaEdits.close(url: asset.url)
        mode = .player
    }

    private func rebuildPreview() {
        guard mode == .edit,
              let document = editDocument,
              let state = document.editState,
              !document.isStale else {
            isPreviewPending = false
            return
        }
        previewGeneration &+= 1
        let generation = previewGeneration
        previewedRanges = state.keepRanges
        isPreviewPending = true
        playback.pause()
        Task { @MainActor in
            do {
                let build = try await MediaCompositionBuilder.build(
                    sourceURL: asset.url,
                    state: state
                )
                guard generation == previewGeneration,
                      mode == .edit else {
                    return
                }
                loaded = .composition
                playback.load(
                    asset: build.composition,
                    sourceURL: asset.url,
                    fileSize: asset.size,
                    audioMix: build.audioMix
                )
                isPreviewPending = false
            } catch let error as MediaCompositionError
                where error == .emptyEdit {
                guard generation == previewGeneration else { return }
                loaded = .none
                previewedRanges = []
                playback.unload()
                isPreviewPending = false
                operationError = nil
            } catch {
                guard generation == previewGeneration else { return }
                loaded = .none
                previewedRanges = []
                playback.unload()
                isPreviewPending = false
                operationError = error.localizedDescription
            }
        }
    }

    private func ensureTranscriptSession() {
        guard transcriptSession == nil else { return }
        let session = TranscriptSession(asset: asset)
        transcriptSession = session
        if transcriptVisible {
            Task { await session.loadCached() }
        }
    }

    private func toggleTranscript() {
        transcriptVisible.toggle()
        guard transcriptVisible else { return }
        ensureTranscriptSession()
        if let transcriptSession {
            Task { await transcriptSession.loadCached() }
        }
    }

    private func applyEdit(_ action: () -> Bool) {
        guard !(project?.mediaEdits.isExportingOperation ?? false) else {
            return
        }
        guard action() else { return }
        operationError = nil
    }

    private func toggleAudition(document: MediaEditDocument) {
        guard !isExportingOperation else { return }
        if playback.isAuditioning {
            playback.stopAudition()
            return
        }
        guard let state = document.editState,
              let selection = state.selection,
              let range = MediaAudition.range(
                  for: selection,
                  in: state
              ) else {
            return
        }
        playback.startAudition(range: range)
    }

    private func removeSilences(
        _ ranges: [MediaTimeRange],
        document: MediaEditDocument
    ) {
        guard !isExportingOperation else { return }
        switch document.removeRanges(ranges) {
        case .changed:
            silenceCandidates = []
            operationError = nil
            showSilencePopover = false
        case .tooShort:
            operationError =
                "Removing these pauses would leave too little material."
        case .unchanged:
            operationError = "No pauses could be removed."
        }
    }

    private func setSelectionStart(_ document: MediaEditDocument) {
        guard !(project?.mediaEdits.isExportingOperation ?? false) else {
            return
        }
        _ = document.setSelectionStart(atSourceTime: sourcePlayhead)
        operationError = nil
    }

    private func setSelectionEnd(_ document: MediaEditDocument) {
        guard !(project?.mediaEdits.isExportingOperation ?? false) else {
            return
        }
        _ = document.setSelectionEnd(atSourceTime: sourcePlayhead)
        operationError = nil
    }

    private func seekSource(
        _ sourceTime: Double,
        document: MediaEditDocument
    ) {
        guard let state = document.editState else { return }
        let edited = state.editedTime(forSourceTime: sourceTime)
        Task { @MainActor in
            await playback.seek(to: edited)
        }
    }

    private func performExport(_ exportMode: MediaExportMode) async {
        guard let project, let document = editDocument else { return }
        operationError = nil
        do {
            _ = try await project.exportMedia(document, mode: exportMode)
        } catch is CancellationError {
            // The user cancelled; the exporter cleaned its temporary file.
        } catch {
            operationError = error.localizedDescription
        }
    }

    /// A menu request is addressed to one project document. Ignore it while
    /// this host is hidden so a retained editor cannot prompt behind another
    /// project; process it when the host becomes visible again.
    private func consumeReplaceRequest() {
        guard projectIsVisible,
              let request = appState?.mediaReplaceRequest,
              let project,
              request.projectID == project.id else {
            return
        }
        guard let editDocument else {
            // The edit session ended before the request was delivered.
            appState?.mediaReplaceRequest = nil
            return
        }
        guard request.documentID == editDocument.id else { return }
        appState?.mediaReplaceRequest = nil
        guard !isExportingOperation, !editDocument.isStale else { return }
        if mode == .edit, editDocument.canReplaceOriginal {
            showReplaceConfirmation = true
        }
    }

    // MARK: - Shared states

    private var loadingState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            ProgressView()
            Text("Loading media…")
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(
                    .system(
                        size: AppTheme.TypeScale.displayLarge,
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(AppTheme.Palette.warning)
            Text("Could not play this file")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))
            Text(message)
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: AppTheme.Layout.emptyDescriptionMaxWidth)
            Text(asset.url.path)
                .font(.system(size: AppTheme.TypeScale.xs, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Open in Default App") {
                NSWorkspace.shared.open(asset.url)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transport: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                BarIconButton(
                    systemName: playback.isPlaying ? "pause.fill" : "play.fill",
                    help: playback.isPlaying ? "Pause" : "Play"
                ) {
                    playback.togglePlayback()
                }
                .disabled(playback.state != .ready)

                BarIconButton(systemName: "gobackward.5", help: "Back 5 seconds") {
                    playback.skip(by: -5)
                }
                .disabled(playback.state != .ready)

                BarIconButton(systemName: "goforward.5", help: "Forward 5 seconds") {
                    playback.skip(by: 5)
                }
                .disabled(playback.state != .ready)

                if playback.hasVideo {
                    BarIconButton(
                        systemName: "backward.frame",
                        help: playback.isFrameRateVerified
                            ? "Previous frame"
                            : "Frame stepping needs verified constant timing"
                    ) {
                        playback.stepFrames(-1)
                    }
                    .disabled(
                        playback.state != .ready
                            || !playback.isFrameRateVerified
                    )

                    BarIconButton(
                        systemName: "forward.frame",
                        help: playback.isFrameRateVerified
                            ? "Next frame"
                            : "Frame stepping needs verified constant timing"
                    ) {
                        playback.stepFrames(1)
                    }
                    .disabled(
                        playback.state != .ready
                            || !playback.isFrameRateVerified
                    )
                }

                Text(positionLabel)
                    .font(.system(size: AppTheme.TypeScale.xs, design: .monospaced))
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { scrubValue ?? playback.elapsed },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(playback.duration, 0.001), // token-exempt: zero-duration guard
                    onEditingChanged: { editing in
                        guard !editing, let value = scrubValue else { return }
                        scrubValue = nil
                        Task { @MainActor in
                            await playback.seek(to: value)
                        }
                    }
                )
                .disabled(playback.state != .ready)

                Text(MediaTimecodeFormatter.elapsed(playback.duration))
                    .font(.system(size: AppTheme.TypeScale.xs, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(playback.volume) },
                        set: { playback.volume = Float($0) }
                    ),
                    in: 0...1
                )
                .frame(maxWidth: AppTheme.Layout.mediaVolumeMaxWidth)

                if playback.hasVideo {
                    Toggle("Loop", isOn: Binding(
                        get: { playback.isLooping },
                        set: { playback.isLooping = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: AppTheme.TypeScale.xs))
                }

                Spacer()

                if let source = playback.timecode.sourceLabel {
                    Text("TC \(source)")
                        .font(.system(size: AppTheme.TypeScale.xxs, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    private var positionLabel: String {
        playback.timecode.sourceLabel
            ?? MediaTimecodeFormatter.elapsed(playback.elapsed)
    }
}
