import Foundation

/// One row in the chip rail, the overview, and the Project menu. The order is
/// stable: real projects in open order, then the demo.
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
    let showsChipRail: Bool

    init(entries: [ProjectSwitcherEntry], showsChipRail: Bool) {
        self.entries = entries
        self.showsChipRail = showsChipRail
    }

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
        // The rail appears only when there is a real choice to make. With one
        // project the compact dropdown is quieter.
        showsChipRail = workspace.projects.count >= 2
    }

    /// Digits 1...9 map to the first nine entries in stable order.
    static func shortcutIndex(for position: Int) -> Int? {
        (0..<9).contains(position) ? position + 1 : nil
    }
}
