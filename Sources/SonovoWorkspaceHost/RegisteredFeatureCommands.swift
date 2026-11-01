import SwiftUI
import SonovoDomainTypes
import SonovoFeatureAPI

@MainActor package struct RegisteredFeatureCommands: Commands {
    package let title: String
    package let featureID: FeatureID
    @Bindable package var state: AppState
    package init(title: String, featureID: FeatureID, state: AppState) {
        self.title = title; self.featureID = featureID; self.state = state
    }
    package var body: some Commands {
        CommandMenu(title) {
            let session = state.liveProject.featureSessions.session(for: featureID)
            if let menu = session?.menus.first(where: { $0.title == title }) {
                menu.makeView(FeatureMenuContext(isEditorSelected: state.selectedFeatureID == featureID,
                    isEditorVisible: state.terminalPresentation != .full,
                    perform: { state.performFeatureCommand($0, expectedOwner: featureID) }))
            } else {
            let commands = session?.commands.filter(\.showsInMenu) ?? []
            let groups = commands.map(\.menuGroup).reduce(into: [Int]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }
            ForEach(groups.indices, id: \.self) { index in
                if index > 0 { Divider() }
                ForEach(commands.filter { $0.menuGroup == groups[index] }, id: \.id) { command in
                    commandButton(command)
                }
            }
            }
        }
    }
    @ViewBuilder private func commandButton(_ command: FeatureCommandContribution) -> some View {
        let button = Button(command.title()) { state.performFeatureCommand(command.id) }
            .disabled(!state.canPerformFeatureCommand(command.id))
        if let shortcut = command.shortcut { button.keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers) }
        else { button }
    }
}

extension AppState {
    package var selectedFeatureID: FeatureID? { liveProject.selectedFeatureID }
    package func canPerformFeatureCommand(_ id: String) -> Bool {
        guard let (_, command) = liveProject.featureSessions.command(id),
              !command.requiresFolderProject || !liveProject.isDemo else { return false }
        return liveProject.featureSessions.canPerformCommand(id, selectedFeature: selectedFeatureID,
            editorIsVisible: terminalPresentation != .full)
    }
    package func canPerformEditorCommand(_ role: FeatureCommandRole) -> Bool {
        guard let command = liveProject.featureSessions.command(for: role, selectedFeature: selectedFeatureID) else { return false }
        return canPerformFeatureCommand(command.id)
    }
    @discardableResult package func performEditorCommand(_ role: FeatureCommandRole) -> Bool {
        guard let command = liveProject.featureSessions.command(for: role, selectedFeature: selectedFeatureID),
              canPerformFeatureCommand(command.id) else { return false }
        performFeatureCommand(command.id)
        return true
    }
    package func performFeatureCommand(_ id: String, expectedOwner: FeatureID? = nil) {
        // Resolve at the click, not when the menu was last rendered.
        let project = liveProject
        guard canPerformFeatureCommand(id), let (owner, command) = project.featureSessions.command(id),
              expectedOwner == nil || expectedOwner == owner else { return }
        command.perform(FeatureCommandInvocation(project: project, revealWorkspace: { [weak self, weak project] in
            guard let self, let project else { return }
            self.activateProject(project)
            if self.terminalPresentation == .full { self.terminalPresentation = .hidden }
            guard let descriptor = project.featureSessions.descriptor(for: owner)?.workspaces.first else { return }
            if project.isDemo, let sampleID = descriptor.legacySampleAssetID {
                if let tab = project.openTabs.first(where: { $0.assetID == sampleID }) { project.selectTab(tab.id) }
                else if project.externalContent?.asset(id: sampleID) != nil { project.openAsset(id: sampleID) }
            } else { project.showWorkspace(featureID: owner, role: descriptor.role) }
        }, revealDocument: { [weak self, weak project] document in
            guard let self, let project,
                  let adapter = project.documentWorkspaces.adapter(for: owner) else { return }
            self.revealDocument(featureID: adapter.featureID, document: document, owner: project)
        }, reportError: { [weak self] title, message in
            guard let self else { return }
            if !runtime.reportError(title: title, message: message) { appAlert = AppAlert(title: title, message: message) }
        }, mediaReplaceRequests: self))
    }
}
