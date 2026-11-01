package enum NavigatorMode: String, CaseIterable, Identifiable, Sendable {
    case production
    case files

    package var id: String { rawValue }

    package var label: String {
        switch self {
        case .production: "Production"
        case .files: "Files"
        }
    }

    package var icon: String {
        switch self {
        case .production: "square.stack.3d.up"
        case .files: "folder"
        }
    }
}
