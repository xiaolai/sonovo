import SwiftUI
import SonovoDomainTypes
import SonovoFeatureAPI

@MainActor package final class CodeFeatureSession: ProjectFeatureSession {
    package let featureID: FeatureID = "builtin.code"
    package let workspace: CodeWorkspace
    package let documentWorkspace: DocumentWorkspaceAdapter?
    package let editors: [FeatureEditorContribution]
    package var lifecycle = FeatureLifecycle()
    package init(workspace: CodeWorkspace) {
        self.workspace = workspace
        self.documentWorkspace = CodeFeature.documentWorkspace(workspace)
        self.editors = CodeFeature.editors(workspace: workspace)
        self.lifecycle = FeatureLifecycle(editorVisibilityChanged: { [weak workspace] in workspace?.setProjectVisible($0) })
        self.lifecycle.visibilityPriority = -10
    }
    package func attachDocumentHost(_ services: DocumentHostServices) {
        workspace.onDocumentClosed = { services.documentClosed($0.id, $0.fileURL) }
        workspace.onDocumentActivated = { services.documentActivated($0) }
        workspace.onDocumentMoved = services.documentMoved
        workspace.isPathOwned = services.isPathOwned
        workspace.isPathOwnedAnywhere = { services.isPathOwned($0, nil) }
        workspace.isEditorTabSelected = services.isEditorSelected
        workspace.reserveDestination = services.reserveDestination
        workspace.releaseDestination = services.releaseDestination
        workspace.isDestinationReserved = services.isDestinationReserved
        if let root = services.root { workspace.setWorkspaceRoot(root) }
    }

    package var statusSummary: FeatureStatusSummary? {
        guard let document = workspace.selectedDocument else { return nil }
        let detail = "\(document.source.components(separatedBy: "\n").count.formatted()) lines"
        let trailing: String
        if !document.isReady {
            trailing = "\(document.language.displayName) · " + (document.refusal?.explanation ?? "Not loaded")
        } else {
            trailing = "\(document.language.displayName) · " + (document.hasBOM ? "UTF-8 BOM" : "UTF-8")
                + " · \(document.lineEnding == .crlf ? "CRLF" : "LF")"
        }
        return FeatureStatusSummary(detail: detail, trailing: trailing)
    }

    package var inspector: FeatureViewContribution? {
        FeatureViewContribution { [weak workspace] request in
            guard let workspace, let asset = request.asset else { return nil }
            return AnyView(CodeInspector(workspace: workspace, asset: asset))
        }
    }

    package var settings: [FeatureSettingsContribution] {
        [FeatureSettingsContribution(id: "builtin.code.settings", sectionID: "editor", title: "Editor", icon: "textformat", slot: "editor.trailing") { AnyView(CodeSettingsRows()) }]
    }

    package var breadcrumb: FeatureBreadcrumbContribution? {
        FeatureBreadcrumbContribution(accessory: FeatureViewContribution { [workspace] _ in
            AnyView(CodeSymbolMenu(workspace: workspace))
        }, detail: { [workspace] request in
            guard let asset = request.asset, asset.kind == .code, let document = workspace.selectedDocument,
                  document.fileURL.standardizedFileURL == asset.url.standardizedFileURL else { return nil }
            let controller = workspace.editorCache.cachedController(for: document.id)
            var parts = [document.language.displayName]
            if let symbol = controller?.symbolName { parts.append(symbol) }
            if let controller { parts.append("L\(controller.cursorLine):\(controller.cursorColumn)") }
            return parts.joined(separator: " · ")
        })
    }

}
