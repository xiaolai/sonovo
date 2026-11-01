import SonovoDomainTypes
import SonovoFeatureAPI
import SonovoMediaEngine

@MainActor package protocol MediaProjectContext: EditorProjectContext {
    var mediaEdits: MediaEditWorkspace { get }
    var canRecordAudio: Bool { get }
    var mediaError: String? { get }
    var pendingMediaSeek: MediaSeekRequest? { get }
    func clearMediaError()
    func takeMediaSeek(for asset: ProjectAsset) -> MediaSeekRequest?
    func startAudioRecording() async -> Bool
    func stopAudioRecording(openWhenFinished: Bool) -> ProjectAsset?
    func exportMedia(_ document: MediaEditDocument, mode: MediaExportMode) async throws -> ProjectAsset
}
