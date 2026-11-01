import Foundation
import SonovoDomainTypes

/// Native authored content can supply rows and prepared files without a
/// folder scan. The host knows neither its bundle nor its document models.
@MainActor package protocol ProjectExternalContent: AnyObject {
    func asset(id: String) -> ExternalEditorAsset?
    func documentURL(for id: String) throws -> URL?
    func resourceAsset(id: String) -> ProjectAsset?
    func documentPreparationFailed(for id: String, kind: AssetKind, error: Error)
    func refresh()
}
