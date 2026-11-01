import Foundation
import Observation
import SonovoWorkspaceHost
import SonovoTerminalFeature

@MainActor @Observable final class BuiltInApplicationRuntime: ApplicationRuntime {
    let playback = SamplePlaybackState()
    let hygiene: TmuxHygieneStore
    let coordinator: TmuxActionCoordinator?
    let archive: TmuxArchiveStore?
    let sessionsWindow: TmuxSessionsWindowModel
    let cleanupScheduler: TmuxCleanupScheduler?
    var mediaErrorAlert: String?
    @ObservationIgnored weak var terminalPaneAdapter: BuiltInTerminalPaneContext?
    init(hygiene: TmuxHygieneStore, coordinator: TmuxActionCoordinator?, archive: TmuxArchiveStore?,
         sessionsWindow: TmuxSessionsWindowModel, cleanupScheduler: TmuxCleanupScheduler?) {
        self.hygiene = hygiene; self.coordinator = coordinator; self.archive = archive
        self.sessionsWindow = sessionsWindow; self.cleanupScheduler = cleanupScheduler
    }
    func projectDidTransition(from previous: Project, to current: Project) {
        if previous.isDemo && !current.isDemo { playback.isPlaying = false }
    }
    func activityText(for project: Project) -> String? {
        guard project.isDemo else { return nil }
        if playback.isPlaying {
            let name = project.selectedAssetID.flatMap { project.externalContent?.asset(id: $0)?.name } ?? "media"
            return "Playing \(name)"
        }
        return playback.production.updated
    }
    func windowTitle(for project: Project) -> String? {
        project.isDemo ? "\(playback.production.title) — \(playback.production.episode)" : nil
    }
    func reportError(title: String, message: String) -> Bool {
        guard title == "Recording" else { return false }
        mediaErrorAlert = message; return true
    }
    func editorVisibilityChanged(project: Project, visible: Bool) {
        if project.isDemo && !visible { playback.isPlaying = false }
    }
    func prepareForTermination() { hygiene.stopCadence(); cleanupScheduler?.stop() }
}
