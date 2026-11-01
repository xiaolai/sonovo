import Foundation
import SonovoTerminalFeature
import SonovoWorkspaceHost

extension Workspace {
    convenience init(demoProject: Project, store: WorkspacePersisting = UserDefaultsWorkspaceStore(),
                     scanner: any ProjectScanning = ProjectScanner(),
                     watchFactory: @escaping ProjectWatchFactory = { FSEventSource(root: $0, onChange: $1) },
                     terminalEnvironment: TerminalEnvironment = .disabled) {
        self.init(demoProject: demoProject, store: store, projectFactory: { request in
            if let reason = request.offlineReason {
                return Project(offlinePath: request.root.path, reason: reason,
                    expectedVolumeIdentifier: request.expectedVolumeIdentifier, scanner: scanner,
                    watchFactory: watchFactory, terminalEnvironment: terminalEnvironment)
            }
            return Project(folderURL: request.root, expectedVolumeIdentifier: request.expectedVolumeIdentifier,
                scanner: scanner, watchFactory: watchFactory, terminalEnvironment: terminalEnvironment)
        })
    }

    var hygieneKnownPaths: TmuxKnownPaths {
        var paths = TmuxKnownPaths()
        for project in projects {
            paths.insertOpen(project.id)
        }
        for path in recentPaths {
            paths.insertRecentClosed(path)
        }
        return paths
    }

}
