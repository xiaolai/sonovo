import SwiftUI
import SonovoDomainTypes
import SonovoFeatureAPI

package enum TerminalFeature {
    package static let metadata = FeatureMetadata(id: "builtin.terminal", displayName: "Terminal")
}
@MainActor package final class TerminalFeatureSession: ProjectFeatureSession {
    package let featureID: FeatureID = "builtin.terminal"
    package let workspace: TerminalSessionsStore
    package var lifecycle = FeatureLifecycle()
    package init(workspace: TerminalSessionsStore) {
        self.workspace = workspace
        self.lifecycle = FeatureLifecycle(projectRecovered: { [weak workspace] in workspace?.restoreTmuxSessions() },
            refreshBackgroundState: { [weak workspace] in workspace?.refreshProcessStates() },
            shutdown: { [weak workspace] in workspace?.shutdownAll(force: true) })
        self.lifecycle.shutdownPriority = 20
        self.lifecycle.projectCloseWarning = { [weak workspace] in
            workspace?.hasLiveDirectProcess == true ? "A terminal in this project is still running a process." : nil
        }
    }
    package var settings: [FeatureSettingsContribution] {
        [FeatureSettingsContribution(id: "builtin.terminal.settings", sectionID: "terminal", title: "Terminal", icon: "terminal", slot: "page") { AnyView(TerminalSettingsPane()) }]
    }

    package var attention: [FeatureAttentionItem] {
        let count = workspace.runningProcessCount
        guard count > 0 else { return [] }
        return [FeatureAttentionItem(id: "builtin.terminal.running", label: "Terminal",
            detail: "\(count) terminal process" + (count == 1 ? "" : "es") + " running",
            symbol: "terminal.fill", priority: 3, role: .runningProcesses, count: count)]
    }

}
