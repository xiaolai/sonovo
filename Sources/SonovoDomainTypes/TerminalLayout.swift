import Foundation

package enum TerminalPresentation: String, CaseIterable, Hashable, Identifiable, Sendable {
    case hidden
    case split
    case full

    package var id: String { rawValue }
}

package enum TerminalDock: String, CaseIterable, Hashable, Identifiable, Sendable {
    case automatic
    case right
    case bottom

    package var id: String { rawValue }

    package var label: String {
        switch self {
        case .automatic: "Automatic"
        case .right: "Right"
        case .bottom: "Bottom"
        }
    }
}

package enum TerminalDockPosition: Sendable {
    case right
    case bottom
    case full
}
