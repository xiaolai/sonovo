import SwiftUI
import SonovoDomainTypes
import SonovoFeatureAPI

@MainActor package enum MediaFeature {
    nonisolated package static var metadata: FeatureMetadata {
        FeatureMetadata(id: "builtin.media", displayName: "Media", documentProviders: descriptors)
    }

    nonisolated package static let descriptors = [
        DocumentProviderDescriptor(id: "builtin.media.audio", featureID: "builtin.media", kind: .audio,
            selectors: ["wav", "aif", "aiff", "mp3", "m4a", "aac", "flac", "ogg", "opus"].map(DocumentSelector.fileExtension)),
        DocumentProviderDescriptor(id: "builtin.media.video", featureID: "builtin.media", kind: .video,
            selectors: ["mp4", "mov", "m4v", "webm", "mkv", "mxf", "avi"].map(DocumentSelector.fileExtension))
    ]
    package static func editors(project: any MediaProjectContext) -> [FeatureEditorContribution] {
        descriptors.map { descriptor in
            FeatureEditorContribution(id: descriptor.id) { request in
                guard let asset = request.asset else {
                    return AnyView(Text("Media editor unavailable."))
                }
                return AnyView(MediaAssetView(asset: asset, project: project,
                    appState: request.mediaReplaceRequests).id(asset.id))
            }
        }
    }
}
