import SwiftUI
import Foundation
import SonovoFileIO
import SonovoDomainTypes
import SonovoFeatureAPI

@MainActor package final class TimelineFeatureSession: ProjectFeatureSession {
    package let featureID: FeatureID = "builtin.timeline"
    package let workspace: TimelineWorkspace
    package let documentWorkspace: DocumentWorkspaceAdapter?
    package let editors: [FeatureEditorContribution]
    package var lifecycle = FeatureLifecycle()
    package init(workspace: TimelineWorkspace) {
        self.workspace = workspace
        self.documentWorkspace = TimelineFeature.documentWorkspace(workspace)
        self.editors = TimelineFeature.editors(workspace: workspace)
        self.lifecycle = FeatureLifecycle(assetsChanged: { [weak workspace] _ in
            if let workspace, let document = workspace.document { workspace.handleExternalChange(url: document.url) }
        }, deactivate: { [weak workspace] in workspace?.cancelJobs() }, shutdown: { [weak workspace] in
            workspace?.prepareForTermination()
        })
        self.lifecycle.willShutdown = { [weak workspace] in workspace?.cancelJobs() }
        self.lifecycle.assetChangePriority = -10
        self.lifecycle.shutdownPriority = 10
    }
    package var commands: [FeatureCommandContribution] {
        [
            FeatureCommandContribution(id: "builtin.timeline.new", title: { "New Timeline" }, requiresVisibleEditor: false, requiresFolderProject: true,
                action: { invocation in
                    guard let project = invocation.project, !project.isDemo, let root = project.root else { return }
                    let base = "Untitled"
                    var url = root.appendingPathComponent("\(base).timeline.json")
                    var index = 2
                    while FileManager.default.fileExists(atPath: url.path) {
                        url = root.appendingPathComponent("\(base) \(index).timeline.json"); index += 1
                    }
                    do { try TimelineFileStore(url: url).save(ProjectTimeline(name: base)) }
                    catch { invocation.reportError("Could not create the timeline", error.localizedDescription); return }
                    let createdURL = url
                    Task { @MainActor in
                        await project.refreshAssetsForNavigation()
                        if let asset = project.assets.first(where: { FilePathPolicy.canonical($0.url) == FilePathPolicy.canonical(createdURL) }) {
                            project.openAsset(asset)
                        } else { invocation.reportError("Could not create the timeline", CocoaError(.fileReadNoSuchFile).localizedDescription) }
                    }
                }),
            FeatureCommandContribution(id: "builtin.timeline.save", title: { "Save Timeline" },
                isEnabled: { [workspace] in workspace.document?.hasUnsavedChanges == true }, requiresVisibleEditor: false,
                shortcut: KeyboardShortcut("s", modifiers: [.command, .option]), menuGroup: 1, perform: { [workspace] in workspace.save() }),
            FeatureCommandContribution(id: "builtin.timeline.undo", title: { "Undo Timeline Edit" },
                isEnabled: { [workspace] in workspace.document?.canUndo == true }, requiresVisibleEditor: false,
                shortcut: KeyboardShortcut("z", modifiers: [.command, .option]), menuGroup: 1, perform: { [workspace] in _ = workspace.document?.undo() }),
            FeatureCommandContribution(id: "builtin.timeline.redo", title: { "Redo Timeline Edit" },
                isEnabled: { [workspace] in workspace.document?.canRedo == true }, requiresVisibleEditor: false,
                shortcut: KeyboardShortcut("z", modifiers: [.command, .option, .shift]), menuGroup: 1, perform: { [workspace] in _ = workspace.document?.redo() })
        ]
    }

}
