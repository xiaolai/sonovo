/// Native application lifecycle and authored-content presentation. Features
/// cannot import Host and never receive this application-owned capability.
@MainActor package protocol ApplicationRuntime: AnyObject {
    func projectDidTransition(from previous: Project, to current: Project)
    func activityText(for project: Project) -> String?
    func windowTitle(for project: Project) -> String?
    func reportError(title: String, message: String) -> Bool
    func editorVisibilityChanged(project: Project, visible: Bool)
    func prepareForTermination()
}
extension ApplicationRuntime {
    package func projectDidTransition(from previous: Project, to current: Project) {}
    package func activityText(for project: Project) -> String? { nil }
    package func windowTitle(for project: Project) -> String? { nil }
    package func reportError(title: String, message: String) -> Bool { false }
    package func editorVisibilityChanged(project: Project, visible: Bool) {}
    package func prepareForTermination() {}
}
@MainActor package final class NoopApplicationRuntime: ApplicationRuntime { package init() {} }
