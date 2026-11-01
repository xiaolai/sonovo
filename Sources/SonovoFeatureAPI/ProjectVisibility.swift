import SwiftUI

private struct ProjectIsVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// True only while this project's editor is actually on screen. A hidden
    /// project and an editor hidden by terminal-full both report false.
    package var projectIsVisible: Bool {
        get { self[ProjectIsVisibleKey.self] }
        set { self[ProjectIsVisibleKey.self] = newValue }
    }
}
