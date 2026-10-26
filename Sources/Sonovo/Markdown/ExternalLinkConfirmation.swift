import AppKit

/// The confirmation step before an external destination leaves the app.
///
/// The decision to ask belongs to `MarkdownLinkActivation`; this type owns
/// only the alert and the single `NSWorkspace` open path, so the rendered
/// viewer and the source link popover cannot drift.
@MainActor
enum ExternalLinkConfirmation {
    struct Request: Equatable {
        let url: URL
        let message: String
        let detail: String
    }

    static func request(for url: URL) -> Request {
        Request(
            url: url,
            message: "Open this link?",
            detail: url.absoluteString
        )
    }

    /// Opens only on the explicit Open button. Cancel and Escape leave
    /// everything untouched.
    static func present(_ request: Request) {
        let alert = NSAlert()
        alert.messageText = request.message
        alert.informativeText = request.detail
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(request.url)
    }
}
