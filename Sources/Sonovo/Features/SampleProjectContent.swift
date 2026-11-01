import Foundation
import SonovoDomainTypes
import SonovoWorkspaceHost
import SonovoMediaEngine
import SonovoMarkdownFeature
import SonovoSubtitleFeature

/// The existing Sample is a native authored-content adapter, not a second
/// set of feature runtimes. User-edited sample files are never reseeded.
@MainActor final class SampleProjectContent: ProjectExternalContent {
    let production: Production
    let documents: SampleProjectDocuments?
    let media: SampleMediaRegistry?
    private let markdown: MarkdownWorkspace
    private let subtitles: SubtitleWorkspace
    private let generation: () -> UInt64
    private let documentNames = ["script-md": "tidewater-script.md", "outline-md": "outline.md", "captions-srt": "captions.srt"]

    init(production: Production, documents: SampleProjectDocuments?, markdown: MarkdownWorkspace,
         subtitles: SubtitleWorkspace, generation: @escaping () -> UInt64) {
        self.production = production; self.documents = documents; self.markdown = markdown; self.subtitles = subtitles
        self.generation = generation
        self.media = documents.map { SampleMediaRegistry(directory: $0.destinationDirectory) }
    }
    var groups: [ProductionStage] {
        _ = generation()
        var groups = production.stages.map { stage in
            ProductionStage(id: stage.id, title: stage.title, assets: stage.assets.map { asset in
                guard asset.kind == .audio, let media = resourceAsset(id: asset.id),
                      let audio = MediaAudioMetadata.describe(url: media.url) else { return asset }
                return ProductionAsset(id: asset.id, name: asset.name, detail: audio.detail, kind: asset.kind)
            })
        }
        if let recordings = media?.productionStage() {
            if let voice = groups.firstIndex(where: { $0.id == "voice" }) { groups.insert(recordings, at: voice + 1) }
            else { groups.append(recordings) }
        }
        return groups
    }
    func asset(id: String) -> ExternalEditorAsset? {
        groups.lazy.flatMap(\.assets).first { $0.id == id } ?? production.asset(id: id)
    }
    func documentURL(for id: String) throws -> URL? {
        guard let name = documentNames[id] else { return nil }
        guard let documents else { throw SampleDocumentError.sourceUnavailable(name) }
        return try documents.documentURL(named: name)
    }
    func documentPreparationFailed(for id: String, kind: AssetKind, error: Error) {
        let name = documentNames[id] ?? id
        let message = "The sample document “\(name)” could not be prepared: \(error.localizedDescription)"
        if kind == .subtitle { subtitles.lastError = message; subtitles.selectedDocumentID = nil }
        else {
            markdown.lastError = message; markdown.selectedDocumentID = nil
            markdown.secondaryDocumentID = nil; markdown.focusedDocumentID = nil
        }
    }
    func refresh() { media?.refresh() }
    func resourceAsset(id: String) -> ProjectAsset? { media?.asset(id: id) ?? audioAsset(id: id) }
    func audioAsset(id: String) -> ProjectAsset? {
        guard let documents, let url = try? documents.documentURL(named: "\(id).wav") else { return nil }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        let size = Int64(values?.fileSize ?? 0), modified = values?.contentModificationDate
        return ProjectAsset(id: id, url: url, name: "\(id).wav", relativePath: "\(id).wav", kind: .audio,
            size: size, modified: modified, revision: AssetRevision.read(of: url) ?? AssetRevision(fileIdentifier: nil, size: size, modified: modified))
    }
}
