import Foundation

/// Services bound to one feature by the composition root. Events cannot name
/// another feature or access its models. Save ownership is project-wide.
@MainActor package struct DocumentHostServices {
    package let root: URL?
    package let isPathOwned: (String, UUID?) -> Bool
    package let isDestinationReserved: (String) -> Bool
    package let reserveDestination: (String, UUID) -> Bool
    package let releaseDestination: (String, UUID) -> Void
    package let documentClosed: (UUID?, URL?) -> Void
    package let documentActivated: (URL?) -> Void
    package let documentMoved: (URL, URL) -> Void
    package let isEditorSelected: () -> Bool
    package let openIndexedAsset: (URL) -> Bool

    package init(root: URL?, isPathOwned: @escaping (String, UUID?) -> Bool,
                 isDestinationReserved: @escaping (String) -> Bool,
                 reserveDestination: @escaping (String, UUID) -> Bool,
                 releaseDestination: @escaping (String, UUID) -> Void,
                 documentClosed: @escaping (UUID?, URL?) -> Void,
                 documentActivated: @escaping (URL?) -> Void,
                 documentMoved: @escaping (URL, URL) -> Void,
                 isEditorSelected: @escaping () -> Bool,
                 openIndexedAsset: @escaping (URL) -> Bool) {
        self.root = root
        self.isPathOwned = isPathOwned
        self.isDestinationReserved = isDestinationReserved
        self.reserveDestination = reserveDestination
        self.releaseDestination = releaseDestination
        self.documentClosed = documentClosed
        self.documentActivated = documentActivated
        self.documentMoved = documentMoved
        self.isEditorSelected = isEditorSelected
        self.openIndexedAsset = openIndexedAsset
    }
}
