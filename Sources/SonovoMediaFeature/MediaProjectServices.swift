import Foundation
import SonovoDomainTypes

/// File registration belongs to the project index; media export, recording,
/// temporary files, backup policy and operation state belong to the feature.
@MainActor package struct MediaProjectServices {
    package let projectName: String
    package let destinationDirectory: () -> URL?
    package let canRecord: () -> Bool
    package let registerCreatedMedia: (URL, AssetKind, Bool) -> ProjectAsset?
    package let replacedAsset: (URL, ProjectAsset) async -> ProjectAsset?
    package init(projectName: String, destinationDirectory: @escaping () -> URL?, canRecord: @escaping () -> Bool,
                 registerCreatedMedia: @escaping (URL, AssetKind, Bool) -> ProjectAsset?,
                 replacedAsset: @escaping (URL, ProjectAsset) async -> ProjectAsset?) {
        self.projectName = projectName
        self.destinationDirectory = destinationDirectory
        self.canRecord = canRecord
        self.registerCreatedMedia = registerCreatedMedia
        self.replacedAsset = replacedAsset
    }
}
