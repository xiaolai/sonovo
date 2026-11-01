import Foundation
import SonovoDomainTypes
import SonovoWorkspaceHost
import SonovoTerminalFeature

@MainActor final class BuiltInTerminalPaneContext: TerminalPaneContext {
    private let state: AppState
    init(state: AppState) { self.state = state }
    var terminalSessions: TerminalSessionsStore { state.terminalSessions }
    var terminalPresentation: TerminalPresentation {
        get { state.terminalPresentation }
        set { state.terminalPresentation = newValue }
    }
    var terminalDock: TerminalDock {
        get { state.terminalDock }
        set { state.terminalDock = newValue }
    }
    var terminalFraction: CGFloat {
        get { state.terminalFraction }
        set { state.terminalFraction = newValue }
    }
}
extension AppState {
    var terminalPaneContext: any TerminalPaneContext {
        if let adapter = nativeRuntime.terminalPaneAdapter { return adapter }
        let adapter = BuiltInTerminalPaneContext(state: self)
        nativeRuntime.terminalPaneAdapter = adapter
        return adapter
    }
}
