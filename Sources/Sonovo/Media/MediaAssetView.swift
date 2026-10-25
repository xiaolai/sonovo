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
    @State private var operationError: String?
    @State private var showReplaceConfirmation = false
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

    private var sourcePlayhead: Double {
        guard mode == .edit,
              let state = editDocument?.editState else {
            return playback.elapsed
        }
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
        .onChange(of: asset.revision) { _, _ in
            handleAssetRevisionChange()
        }
        .onChange(of: playback.hasAudio) { _, hasAudio in
            guard hasAudio, !playback.hasVideo else { return }
            waveform.load(url: asset.url, revision: asset.revision)
        }
        .onChange(of: editDocument?.editState?.keepRanges) { _, ranges in
            guard mode == .edit,
                  editDocument?.isStale != true,
                  let ranges,
                  ranges != previewedRanges else {
                return
            }
            operationError = nil
            rebuildPreview()
        }
        .onChange(of: projectIsVisible) { _, visible in
            if !visible {
                playback.pause()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                project?.mediaEdits.recorder.refreshPermission()
            }
        }
        .onChange(of: appState?.mediaReplaceRequest ?? false) { _, requested in
            guard requested else { return }
            appState?.mediaReplaceRequest = false
            if mode == .edit,
               editDocument?.canReplaceOriginal == true {
                showReplaceConfirmation = true
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
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The edited file replaces the source. A timestamped backup is kept outside the project first."
            )
        }
        .onDisappear {
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
            if case .failed(let message) = waveform.state {
                Text(message)
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
                    operationError: operationError,
                    onReload: reloadSource
                )
            }

            if editDocument?.isStale == true {
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
                    }
                )
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
        } else if showsVideoInEdit {
            VStack(spacing: AppTheme.Spacing.zero) {
                if playback.state == .ready {
                    MediaPlayerView(player: playback.player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AppTheme.Palette.black)
                } else {
                    loadingState
                }
                selectionStrip(document)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.sm)
                    .background(Color.appCard)
            }
        } else {
            VStack(spacing: AppTheme.Spacing.md) {
                if case .failed(let message) = waveform.state {
                    Text(message)
                        .font(.system(size: AppTheme.TypeScale.sm))
                        .foregroundStyle(.secondary)
                }
                selectionStrip(document)
                    .frame(height: AppTheme.Size.waveformHeight)
                if waveform.state == .loading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(AppTheme.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func selectionStrip(_ document: MediaEditDocument) -> some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            if showsVideoInEdit {
                HStack {
                    Text("Source trim range")
                        .font(.system(size: AppTheme.TypeScale.xxs))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            MediaSelectionWaveformView(
                data: showsVideoInEdit ? nil : waveform.data,
                sourceDuration: document.sourceDuration,
                removedRanges: document.editState?.removedRanges ?? [],
                selection: document.selection,
                playhead: sourcePlayhead,
                compact: showsVideoInEdit,
                onSeek: { sourceTime in
                    seekSource(sourceTime, document: document)
                },
                onSelect: { start, end in
                    _ = document.setSelection(start: start, end: end)
                    operationError = nil
                }
            )
            .frame(
                height: showsVideoInEdit
                    ? AppTheme.Size.mediaTrimStripHeight
                    : AppTheme.Size.waveformHeight
            )
        }
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
                Button("Discard Edit", role: .destructive) {
                    discardEdit()
                }
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
        project.clearMediaError()
        let document = project.mediaEdits.document(for: asset)
        editDocument = document
        project.mediaEdits.activate(document)
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
        pendingEditStart = false
        pendingReload = false
        previewGeneration &+= 1
        previewedRanges = []
        if let project, let editDocument {
            project.mediaEdits.deactivate(editDocument)
        }
        editDocument = nil
        operationError = nil
        if loaded == .composition || playback.state == .idle {
            loadSource()
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
            if document.editState == nil {
                // A successful replace discards the old document; the
                // replaced source has no edit decision yet. Return to the
                // player rather than pretending an empty edit is active.
                project.mediaEdits.close(url: asset.url)
                mode = .player
                return
            }
            if document.isStale {
                playback.pause()
                playback.unload()
                loaded = .none
                previewGeneration &+= 1
                previewedRanges = []
            }
        } else {
            loadSource()
        }
    }

    private func reloadSource() {
        guard editDocument != nil else { return }
        operationError = nil
        pendingReload = true
        pendingEditStart = false
        previewedRanges = []
        previewGeneration &+= 1
        loaded = .source
        playback.load(url: asset.url)
        if asset.kind == .audio {
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
            return
        }
        previewGeneration &+= 1
        let generation = previewGeneration
        previewedRanges = state.keepRanges
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
                    fileSize: asset.size
                )
            } catch let error as MediaCompositionError
                where error == .emptyEdit {
                guard generation == previewGeneration else { return }
                loaded = .none
                previewedRanges = []
                playback.unload()
                operationError = nil
            } catch {
                guard generation == previewGeneration else { return }
                loaded = .none
                previewedRanges = []
                playback.unload()
                operationError = error.localizedDescription
            }
        }
    }

    private func applyEdit(_ action: () -> Bool) {
        guard action() else { return }
        operationError = nil
    }

    private func setSelectionStart(_ document: MediaEditDocument) {
        _ = document.setSelectionStart(atSourceTime: sourcePlayhead)
        operationError = nil
    }

    private func setSelectionEnd(_ document: MediaEditDocument) {
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
