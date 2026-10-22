import Foundation

/// Workspace state lives in preferences, not in the project folder. No
/// manifest, no marker file: a folder is a project.
protocol WorkspacePersisting: AnyObject {
    var projectPaths: [String] { get set }
    var activePath: String? { get set }
    var recentPaths: [String] { get set }
    var selections: [String: String] { get set }
    var volumeIdentifiers: [String: String] { get set }
    /// Asset IDs of the file tabs each project had open.
    var openTabs: [String: [String]] { get set }
}

final class UserDefaultsWorkspaceStore: WorkspacePersisting {
    private enum Key {
        static let projects = "sonovo.workspace.projects"
        static let active = "sonovo.workspace.active"
        static let recent = "sonovo.workspace.recent"
        static let selection = "sonovo.workspace.selection"
        static let volumes = "sonovo.workspace.volumes"
        static let openTabs = "sonovo.workspace.openTabs"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var projectPaths: [String] {
        get { defaults.stringArray(forKey: Key.projects) ?? [] }
        set { defaults.set(newValue, forKey: Key.projects) }
    }

    var activePath: String? {
        get { defaults.string(forKey: Key.active) }
        set { defaults.set(newValue, forKey: Key.active) }
    }

    var recentPaths: [String] {
        get { defaults.stringArray(forKey: Key.recent) ?? [] }
        set { defaults.set(newValue, forKey: Key.recent) }
    }

    var selections: [String: String] {
        get { defaults.dictionary(forKey: Key.selection) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Key.selection) }
    }

    var volumeIdentifiers: [String: String] {
        get { defaults.dictionary(forKey: Key.volumes) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Key.volumes) }
    }

    var openTabs: [String: [String]] {
        get {
            defaults.dictionary(forKey: Key.openTabs) as? [String: [String]]
                ?? [:]
        }
        set { defaults.set(newValue, forKey: Key.openTabs) }
    }
}

final class InMemoryWorkspaceStore: WorkspacePersisting {
    var projectPaths: [String] = []
    var activePath: String?
    var recentPaths: [String] = []
    var selections: [String: String] = [:]
    var volumeIdentifiers: [String: String] = [:]
    var openTabs: [String: [String]] = [:]
}
