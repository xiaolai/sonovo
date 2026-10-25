import Foundation

/// One row in the project menu and the overview. The order is stable: real
/// projects in open order, then the demo.
struct ProjectSwitcherEntry: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let detail: String
    let isDemo: Bool
    let isActive: Bool
    let canClose: Bool
    /// 1...9 for the first nine entries; nil for the rest.
    let shortcutIndex: Int?
    let attention: ProjectAttentionSnapshot
}

struct ProjectSwitcherModel: Equatable, Sendable {
    let entries: [ProjectSwitcherEntry]

    @MainActor
    init(workspace: Workspace) {
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
    static func shortcutIndex(for position: Int) -> Int? {
        (0..<9).contains(position) ? position + 1 : nil
    }
}
