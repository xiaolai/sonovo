import Foundation

/// What activating a link destination does, after the security allowlist.
///
/// One model serves the rendered viewer and the source link popover, so the
/// two surfaces cannot disagree about which links open silently. Every
/// destination that leaves the app asks first; fragments and workspace-local
/// paths keep the routing their surface already has.
public enum MarkdownLinkActivation: Sendable, Equatable {
    /// Opens without asking: fragments and workspace-local paths.
    case openDirectly(MarkdownSecurity.LinkKind)
    /// Leaves the app; the destination is shown and the user confirms.
    case confirmBeforeOpening(URL)
    /// The security policy refused the destination.
    case refused(String)

    public static func decide(_ destination: String) -> MarkdownLinkActivation {
        let trimmed = destination.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        switch MarkdownSecurity.linkDecision(for: trimmed) {
        case .denied(let reason):
            return .refused(reason)
        case .allowed(.external), .allowed(.mailto):
            // Both hand the destination to another application; neither
            // opens without an explicit confirmation.
            guard let url = URL(string: trimmed) else {
                return .refused("invalid destination")
            }
            return .confirmBeforeOpening(url)
        case .allowed(let kind):
            return .openDirectly(kind)
        }
    }
}
