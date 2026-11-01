import Foundation
import SonovoDomainTypes

@MainActor package protocol TerminalPaneContext: AnyObject {
    var terminalSessions: TerminalSessionsStore { get }
    var terminalPresentation: TerminalPresentation { get set }
    var terminalDock: TerminalDock { get set }
    var terminalFraction: CGFloat { get set }
}
