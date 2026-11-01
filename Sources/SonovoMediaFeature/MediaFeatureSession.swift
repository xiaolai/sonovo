import SwiftUI
import Foundation
import Observation
import SonovoMediaEngine
import SonovoDomainTypes
import SonovoFeatureAPI

@MainActor @Observable package final class MediaFeatureSession: ProjectFeatureSession, MediaProjectContext {
    package let featureID: FeatureID = "builtin.media"
    package let workspace: MediaEditWorkspace
    private weak var editorProject: (any MediaNavigationContext)?
    package var editors: [FeatureEditorContribution] { MediaFeature.editors(project: self) }
    package func attachEditorProject(_ project: any MediaNavigationContext) { editorProject = project }
    package var mediaEdits: MediaEditWorkspace { workspace }
    package var id: String { editorProject?.id ?? "" }
    package var root: URL? { editorProject?.root }
    package var isDemo: Bool { editorProject?.isDemo == true }
    package var assets: [ProjectAsset] { editorProject?.assets ?? [] }
    package var selectedAsset: ProjectAsset? { editorProject?.selectedAsset }
    package var scanRevision: UInt64 { editorProject?.scanRevision ?? 0 }
    package var isOffline: Bool { editorProject?.isOffline ?? true }
    package var pendingMediaSeek: MediaSeekRequest? { editorProject?.pendingMediaSeek }
    package func takeMediaSeek(for asset: ProjectAsset) -> MediaSeekRequest? { editorProject?.takeMediaSeek(for: asset) }
    package func openAsset(_ asset: ProjectAsset) { editorProject?.openAsset(asset) }
    package func refreshNow() async { await editorProject?.refreshNow() }
    package func refreshAssetsForNavigation() async { await editorProject?.refreshAssetsForNavigation() }
    package func fileCloseAction(at url: URL, kind: AssetKind, canonicalPaths: Bool) -> (@MainActor () async -> Void)? {
        editorProject?.fileCloseAction(at: url, kind: kind, canonicalPaths: canonicalPaths)
    }
    package func mediaReferenceState(for reference: MediaReference, documentURL: URL?) -> MediaReferenceState {
        editorProject?.mediaReferenceState(for: reference, documentURL: documentURL) ?? .missing
    }
    package func openMediaReference(_ reference: MediaReference, documentURL: URL?) {
        editorProject?.openMediaReference(reference, documentURL: documentURL)
    }
    package var lifecycle = FeatureLifecycle()
    package private(set) var mediaError: String?
    package private(set) var mediaGeneration: UInt64 = 0
    private var recordingDestinationDirectory: URL?
    private var services: MediaProjectServices?

    package func attachProject(_ services: MediaProjectServices) {
        self.services = services
        lifecycle = FeatureLifecycle(deactivate: { [weak self] in
            self?.stopOrCancelRecordingForLifecycle()
            self?.workspace.cancelJobs()
        }, invalidate: { [weak self] in
            self?.stopOrCancelRecordingForLifecycle()
            self?.workspace.cancelJobs()
            self?.workspace.closeAll()
        }, shutdown: { [weak self] in
            self?.stopOrCancelRecordingForLifecycle()
            self?.workspace.cancelJobs()
            self?.workspace.closeAll()
        })
        lifecycle.willShutdown = lifecycle.shutdown
        lifecycle.shutdown = nil
        lifecycle.shutdownPriority = -10
        lifecycle.closeAssetTab = { [weak self] tab in
            guard let self, tab.kind == .audio || tab.kind == .video else { return false }
            stopOrCancelRecordingForLifecycle()
            if let url = tab.url { workspace.close(url: url) }
            return true
        }
    }
    package var mediaDestinationDirectory: URL? { services?.destinationDirectory() }
    package var canRecordAudio: Bool { services?.canRecord() == true }
    package var isRecordingAudio: Bool { workspace.recorder.isRecording }
    package func clearMediaError() { mediaError = nil }
    package func stopOrCancelRecordingForLifecycle() {
        if workspace.recorder.isRecording { _ = stopAudioRecording(openWhenFinished: false) }
        else if workspace.recorder.isPreparing {
            workspace.recorder.cancel()
            recordingDestinationDirectory = nil
        }
    }
    package init(workspace: MediaEditWorkspace) { self.workspace = workspace }
    package func startAudioRecording() async -> Bool {
        mediaError = nil
        guard canRecordAudio,
              let destination = mediaDestinationDirectory else {
            mediaError = "This project has no writable folder for recordings."
            return false
        }
        guard !workspace.isExportingOperation else {
            mediaError = "Wait for the current export to finish before recording."
            return false
        }
        if workspace.recorder.isRecording { return true }
        guard !workspace.recorder.isPreparing else {
            mediaError = "A recording is already starting."
            return false
        }
        do {
            let temporary = try MediaStorage.makeTemporaryURL(
                pathExtension: "wav"
            )
            try await workspace.recorder.start(to: temporary)
            recordingDestinationDirectory = destination
            return true
        } catch is CancellationError {
            mediaError = nil
            return false
        } catch {
            mediaError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    package func stopAudioRecording(openWhenFinished: Bool = true) -> ProjectAsset? {
        guard let temporary = workspace.recorder.stop() else {
            if let error = workspace.recorder.lastError {
                mediaError = "The recording could not be saved: \(error)"
            }
            return nil
        }
        guard let destination = recordingDestinationDirectory
                ?? mediaDestinationDirectory else {
            mediaError = "This project has no writable folder for recordings."
            MediaStorage.removeIfPresent(temporary)
            return nil
        }
        recordingDestinationDirectory = nil
        let name = "Recording-\(MediaStorage.timestamp()).wav"
        let target = MediaStorage.uniqueURL(
            in: destination,
            preferredName: name
        )
        do {
            try MediaStorage.installAtomically(
                from: temporary,
                to: target,
                replacing: false
            )
        } catch {
            mediaError = "The recording could not be saved (temporary file "
                + "remains at \(temporary.path)): "
                + error.localizedDescription
            return nil
        }
        MediaStorage.removeIfPresent(temporary)
        let asset = services?.registerCreatedMedia(target, .audio, openWhenFinished)
        if asset != nil {
            mediaGeneration &+= 1
        }
        return asset
    }

    package func cancelAudioRecording() {
        workspace.recorder.cancel()
        recordingDestinationDirectory = nil
        mediaError = nil
    }

    /// Exports the document's current decision as a new take or replaces the
    /// source after keeping a backup. The source is never touched until the
    /// exporter has produced and verified a complete file.
    package func exportMedia(
        _ document: MediaEditDocument,
        mode: MediaExportMode
    ) async throws -> ProjectAsset {
        guard let destination = mediaDestinationDirectory else {
            throw MediaExportError.exportFailed(
                "This project has no writable folder for exports."
            )
        }
        guard !document.isStale, let state = document.editState else {
            throw MediaStorageError.sourceChanged(document.asset.name)
        }
        mediaError = nil
        guard workspace.beginExport(document) else {
            throw MediaExportError.busy
        }
        defer { workspace.endExport(document) }
        do {
            let outcome = try await workspace.exportService.export(
                source: document.asset,
                state: state,
                destinationDirectory: destination,
                projectName: services?.projectName ?? "Project",
                mode: mode
            )
            switch mode {
            case .newTake:
                let kind = Self.mediaKind(for: outcome.url)
                guard let asset = services?.registerCreatedMedia(outcome.url, kind, true) else {
                    throw MediaExportError.missingOutput
                }
                mediaGeneration &+= 1
                return asset
            case .replaceOriginal:
                workspace.discardDocument(for: document.asset.url)
                guard let asset = await services?.replacedAsset(outcome.url, document.asset) else {
                    throw MediaExportError.missingOutput
                }
                mediaGeneration &+= 1
                return asset
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            mediaError = error.localizedDescription
            throw error
        }
    }

    private static func mediaKind(for url: URL) -> AssetKind {
        ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) ? .video : .audio
    }

    package var activity: FeatureActivity? {
        if isRecordingAudio { return FeatureActivity(text: "Recording audio…") }
        if workspace.exportService.isBusy { return FeatureActivity(text: "Exporting media…", priority: 1) }
        return nil
    }
    package var commands: [FeatureCommandContribution] {
        [
            FeatureCommandContribution(id: "builtin.media.record", title: { [weak self] in self?.isRecordingAudio == true ? "Stop Recording" : "Record Audio…" },
                isEnabled: { [weak self] in
                    guard let self else { return false }
                    return isRecordingAudio || (canRecordAudio && !workspace.isExportingOperation)
                }, requiresVisibleEditor: false, role: .record, action: { [weak self] invocation in
                    guard let self else { return }
                    if isRecordingAudio {
                        if stopAudioRecording() == nil, let message = mediaError { invocation.reportError("Recording", message) }
                    } else {
                        Task { @MainActor in
                            if !(await self.startAudioRecording()), let message = self.mediaError { invocation.reportError("Recording", message) }
                        }
                    }
                }),
            editCommand("trim", title: "Trim to Selection", group: 1, enabled: { $0.canTrimToSelection }) { _ = $0.trimToSelection() },
            editCommand("delete", title: "Delete Selection", group: 1, enabled: { $0.canDeleteSelection }) { _ = $0.deleteSelection() },
            editCommand("reset", title: "Reset Edit", group: 1, enabled: { $0.canReset }) { _ = $0.reset() },
            editCommand("undo", title: "Undo Media Edit", group: 2, shortcut: KeyboardShortcut("z", modifiers: [.command, .option]),
                enabled: { $0.canUndo }) { _ = $0.undo() },
            editCommand("redo", title: "Redo Media Edit", group: 2, shortcut: KeyboardShortcut("z", modifiers: [.command, .option, .shift]),
                enabled: { $0.canRedo }) { _ = $0.redo() },
            FeatureCommandContribution(id: "builtin.media.save-take", title: { "Save Take" },
                isEnabled: { [workspace] in !workspace.isExportingOperation && workspace.activeDocument?.canExport == true },
                shortcut: KeyboardShortcut("s", modifiers: [.command, .option]), menuGroup: 3,
                perform: { [weak self, workspace] in
                    guard let self, let document = workspace.activeDocument else { return }
                    Task { _ = try? await self.exportMedia(document, mode: .newTake) }
                }),
            FeatureCommandContribution(id: "builtin.media.replace-original", title: { "Replace Original…" },
                isEnabled: { [workspace] in !workspace.isExportingOperation && workspace.activeDocument?.canReplaceOriginal == true },
                menuGroup: 3, action: { [workspace] invocation in
                    guard let project = invocation.project, let document = workspace.activeDocument else { return }
                    invocation.mediaReplaceRequests?.mediaReplaceRequest = MediaReplaceRequest(projectID: project.id, documentID: document.id)
                })
        ]
    }
    private func editCommand(_ id: String, title: String, group: Int, shortcut: KeyboardShortcut? = nil,
                             enabled: @escaping (MediaEditDocument) -> Bool,
                             perform: @escaping (MediaEditDocument) -> Void) -> FeatureCommandContribution {
        FeatureCommandContribution(id: "builtin.media." + id, title: { title },
            isEnabled: { [workspace] in
                !workspace.isExportingOperation && workspace.activeDocument.map(enabled) == true
            }, shortcut: shortcut, menuGroup: group, perform: { [workspace] in
                guard let document = workspace.activeDocument else { return }
                perform(document)
            })
    }

    package var settings: [FeatureSettingsContribution] {
        [FeatureSettingsContribution(id: "builtin.media.output-settings", sectionID: "audio", title: "Audio", icon: "waveform", slot: "audio.device") { AnyView(AudioOutputSettingsRow()) }]
    }

}
