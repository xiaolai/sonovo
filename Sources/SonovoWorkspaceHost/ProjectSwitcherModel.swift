import Foundation

/// One row in the project menu and the overview. The order is stable: real
/// projects in open order, then the demo.
package struct ProjectSwitcherEntry: Identifiable, Equatable, Sendable {
    package let id: String
    package let name: String
    package let detail: String
    package let isDemo: Bool
    package let isActive: Bool
    package let canClose: Bool
    /// 1...9 for the first nine entries; nil for the rest.
    package let shortcutIndex: Int?
    package let attention: ProjectAttentionSnapshot
}

package struct ProjectSwitcherModel: Equatable, Sendable {
    package let entries: [ProjectSwitcherEntry]

    @MainActor
    package init(workspace: Workspace) {
        let activeID = workspace.liveProject.id
        entries = workspace.allProjects.enumerated().map { index, project in
            ProjectSwitcherEntry(
                id: project.id,
                name: project.isDemo ? "Sample" : project.name,
                detail: project.isDemo
                    ? "Built-in sample project"
                    : (project.root?.path ?? project.id),
                isDemo: project.isDemo,
                isActive: project.id == activeID,
                canClose: !project.isDemo,
                shortcutIndex: Self.shortcutIndex(for: index),
                attention: project.attention
            )
        }
    }

    /// Digits 1...9 map to the first nine entries in stable order.
    package static func shortcutIndex(for position: Int) -> Int? {
        (0..<9).contains(position) ? position + 1 : nil
    }
}
