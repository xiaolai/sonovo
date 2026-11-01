import Foundation
import SonovoDomainTypes
import SonovoFeatureAPI

package enum FeatureSessionRegistrationError: Error, Equatable {
    case invalidMetadata(FeatureID)
    case duplicateMetadata(FeatureID)
    case duplicateSession(FeatureID)
    case unknownSession(FeatureID)
    case mismatchedDocumentOwner(FeatureID)
    case duplicateCommand(String)
    case duplicateSettings(String)
    case invalidCommandID(String)
    case mismatchedEditorOwner(FeatureID)
}

@MainActor package final class FeatureSessionRegistry {
    package let metadata: [FeatureMetadata]
    package let sessions: [any ProjectFeatureSession]
    package let documents: DocumentWorkspaceRegistry
    package let editors: FeatureEditorRegistry
    private let byID: [FeatureID: any ProjectFeatureSession]
    private let metadataByID: [FeatureID: FeatureMetadata]
    private let providerOwners: [EditorProviderID: FeatureID]
    private var lastEditorVisibility: Bool?
#if SONOVO_MODULAR_E2E_PROBE
    package var visibilityProbe: ((Bool) -> Void)?
#endif
    private let commandOwners: [String: FeatureID]

    package init(metadata: [FeatureMetadata], sessions: [any ProjectFeatureSession]) throws {
        var metadataByID: [FeatureID: FeatureMetadata] = [:]
        var providerOwners: [EditorProviderID: FeatureID] = [:]
        for descriptor in metadata {
            guard descriptor.id.isValid,
                  descriptor.documentProviders.allSatisfy({ $0.featureID == descriptor.id }),
                  Set(descriptor.workspaces.map(\.role)).count == descriptor.workspaces.count,
                  descriptor.workspaces.allSatisfy({ workspace in
                      !workspace.role.isEmpty && !workspace.role.contains(":")
                          && descriptor.documentProviders.contains { $0.id == workspace.editorProviderID }
                  }) else { throw FeatureSessionRegistrationError.invalidMetadata(descriptor.id) }
            guard metadataByID.updateValue(descriptor, forKey: descriptor.id) == nil else {
                throw FeatureSessionRegistrationError.duplicateMetadata(descriptor.id)
            }
            for provider in descriptor.documentProviders { providerOwners[provider.id] = descriptor.id }
        }
        let catalogue = try DocumentRecognitionCatalogue(metadata.flatMap(\.documentProviders))
        var byID: [FeatureID: any ProjectFeatureSession] = [:]
        var commandOwners: [String: FeatureID] = [:]
        var settingsIDs = Set<String>()
        for session in sessions {
            guard metadataByID[session.featureID] != nil else { throw FeatureSessionRegistrationError.unknownSession(session.featureID) }
            guard byID.updateValue(session, forKey: session.featureID) == nil else {
                throw FeatureSessionRegistrationError.duplicateSession(session.featureID)
            }
            if let workspace = session.documentWorkspace, workspace.featureID != session.featureID {
                throw FeatureSessionRegistrationError.mismatchedDocumentOwner(session.featureID)
            }
            for pane in session.settings where !settingsIDs.insert(pane.id).inserted {
                throw FeatureSessionRegistrationError.duplicateSettings(pane.id)
            }
            for editor in session.editors where providerOwners[editor.id] != session.featureID {
                throw FeatureSessionRegistrationError.mismatchedEditorOwner(session.featureID)
            }
            for command in session.commands {
                guard command.id.hasPrefix(session.featureID.rawValue + "."), FeatureID(rawValue: command.id).isValid else {
                    throw FeatureSessionRegistrationError.invalidCommandID(command.id)
                }
                guard commandOwners.updateValue(session.featureID, forKey: command.id) == nil else {
                    throw FeatureSessionRegistrationError.duplicateCommand(command.id)
                }
            }
        }
        self.metadata = metadata
        self.sessions = sessions
        self.byID = byID
        self.metadataByID = metadataByID
        self.providerOwners = providerOwners
        self.commandOwners = commandOwners
        self.documents = try DocumentWorkspaceRegistry(sessions.compactMap(\.documentWorkspace))
        self.editors = try FeatureEditorRegistry(catalogue: catalogue, contributions: sessions.flatMap(\.editors))
    }

    package func session(for id: FeatureID) -> (any ProjectFeatureSession)? { byID[id] }
    package func descriptor(for id: FeatureID) -> FeatureMetadata? { metadataByID[id] }
    package func descriptor(for provider: EditorProviderID) -> FeatureMetadata? {
        providerOwners[provider].flatMap { metadataByID[$0] }
    }
    package func session(forProvider provider: EditorProviderID) -> (any ProjectFeatureSession)? {
        providerOwners[provider].flatMap { byID[$0] }
    }
    package func command(_ id: String) -> (owner: FeatureID, command: FeatureCommandContribution)? {
        guard let owner = commandOwners[id], let command = byID[owner]?.commands.first(where: { $0.id == id }) else { return nil }
        return (owner, command)
    }
    package func command(for role: FeatureCommandRole, selectedFeature: FeatureID?) -> FeatureCommandContribution? {
        let candidates = sessions.flatMap { session in
            session.commands.filter { $0.role == role && (!$0.requiresSelectedEditor || session.featureID == selectedFeature) }
        }
        return candidates.count == 1 ? candidates.first : nil
    }
    package func canPerformCommand(_ id: String, selectedFeature: FeatureID?, editorIsVisible: Bool) -> Bool {
        guard let (owner, command) = command(id), command.isEnabled() else { return false }
        return (!command.requiresSelectedEditor || owner == selectedFeature)
            && (!command.requiresVisibleEditor || editorIsVisible)
    }
    package var settings: [FeatureSettingsContribution] { sessions.flatMap(\.settings) }
    package var activity: FeatureActivity? {
        sessions.compactMap(\.activity).min { $0.priority < $1.priority }
    }
    package var attention: [FeatureAttentionItem] {
        sessions.flatMap(\.attention).sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
    }
    package func editorVisibilityChanged(_ visible: Bool) {
        guard lastEditorVisibility != visible else { return }
        lastEditorVisibility = visible
#if SONOVO_MODULAR_E2E_PROBE
        visibilityProbe?(visible)
#endif
        for (_, session) in sessions.enumerated().sorted(by: {
            ($0.element.lifecycle.visibilityPriority, $0.offset) < ($1.element.lifecycle.visibilityPriority, $1.offset)
        }) { session.lifecycle.editorVisibilityChanged?(visible) }
    }
    package func projectRecovered() {
        for session in sessions { session.lifecycle.projectRecovered?() }
    }
    package func refreshBackgroundState() {
        for session in sessions { session.lifecycle.refreshBackgroundState?() }
    }
    package var projectCloseWarning: String? {
        sessions.lazy.compactMap { $0.lifecycle.projectCloseWarning?() }.first
    }
    package func confirmProjectClose() -> Bool {
        sessions.allSatisfy { $0.lifecycle.confirmProjectClose?() ?? true }
    }
    package func closeAssetTab(_ tab: FeatureAssetTabClose) -> Bool {
        for session in sessions where session.lifecycle.closeAssetTab?(tab) == true { return true }
        return false
    }
    package func assetsChanged(_ assets: [ProjectAsset]) {
        // Explicit phases preserve ordering when a source change participates
        // in more than one feature. Registration order is the stable tie-break.
        for (_, session) in sessions.enumerated().sorted(by: {
            ($0.element.lifecycle.assetChangePriority, $0.offset) < ($1.element.lifecycle.assetChangePriority, $1.offset)
        }) { session.lifecycle.assetsChanged?(assets) }
    }
    package func activate() { for session in sessions { session.lifecycle.activate?() } }
    package func deactivate() { for session in sessions { session.lifecycle.deactivate?() } }
    package func invalidate() { for session in sessions { session.lifecycle.invalidate?() } }
    package func shutdown() {
        // Cancellation precedes document teardown. In normal composition this
        // stops/commits recording, cancels media jobs, then timeline exports.
        for session in sessions { session.lifecycle.willShutdown?() }
        for (_, session) in sessions.enumerated().sorted(by: {
            ($0.element.lifecycle.shutdownPriority, $0.offset) < ($1.element.lifecycle.shutdownPriority, $1.offset)
        }) {
            if let shutdown = session.lifecycle.shutdown { shutdown() }
            else { session.documentWorkspace?.shutdown() }
        }
    }

}
