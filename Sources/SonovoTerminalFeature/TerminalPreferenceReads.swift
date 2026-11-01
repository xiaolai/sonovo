import SonovoFileIO
import SonovoDomainTypes
import SonovoDesignSystem

extension Preferences {
    /// The account's login shell. "System Default" resolves here so the
    /// login-shell toggle has an effect without an explicit choice.
    package static var systemShell: String {
        TerminalShell.accountShell
    }

    /// The shell handed to Ghostty and tmux. Never empty, and never a path
    /// that cannot run: a shell removed after it was chosen falls back to
    /// the account shell instead of leaving the pane unable to start.
    package static var effectiveShell: String {
        TerminalShell.resolve(shell)
    }

    /// Whether the stored shell is set but unusable.
    package static var shellIsMissing: Bool {
        TerminalShell.isMissing(shell)
    }

}
