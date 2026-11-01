import SwiftUI
import SonovoDomainTypes
import SonovoFeatureAPI

package enum ViewerFeature {
    nonisolated package static var metadata: FeatureMetadata {
        FeatureMetadata(id: "builtin.viewer", displayName: "Viewer", documentProviders: descriptors)
    }

    package static let id: FeatureID = "builtin.viewer"
    package static let descriptors: [DocumentProviderDescriptor] = [
        descriptor("image", kind: .image, extensions: ViewerRouter.imageExtensions),
        descriptor("pdf", kind: .document, extensions: ["pdf"]),
        descriptor("web", kind: .html, extensions: ["html", "htm"]),
        descriptor("svg", kind: .image, extensions: ["svg"]),
        descriptor("quicklook.image", kind: .image, extensions: ["psd", "psb", "ai", "eps"]),
        descriptor("quicklook.document", kind: .document, extensions: ViewerRouter.quickLookExtensions.subtracting(["psd", "psb", "ai", "eps"])),
        descriptor("metadata.archive", kind: .archive, extensions: ["zip", "mhl", "ascmhl"])
    ]

    private static func descriptor(_ name: String, kind: AssetKind, extensions: Set<String>) -> DocumentProviderDescriptor {
        DocumentProviderDescriptor(id: EditorProviderID(rawValue: "builtin.viewer." + name), featureID: id,
                                   kind: kind, selectors: extensions.sorted().map(DocumentSelector.fileExtension))
    }

    @MainActor package static var editors: [FeatureEditorContribution] {
        descriptors.map { descriptor in
            FeatureEditorContribution(id: descriptor.id) { request in
                guard let asset = request.asset else { return AnyView(EmptyView()) }
                return makeView(asset: asset, assets: request.project.assets)
            }
        }
    }

    @MainActor private static func makeView(asset: ProjectAsset, assets: [ProjectAsset]) -> AnyView {
        let identity = "\(asset.id)-\(asset.revision.token)"
        switch ViewerRouter.route(for: asset) {
        case .image:
            // Candidate changes must not reset the displayed image's zoom/pan.
            return AnyView(ImageDocumentView(asset: asset, comparisonCandidates: assets.filter {
                $0.id != asset.id && ViewerRouter.route(for: $0) == .image
            }).id(identity))
        case .pdf: return AnyView(PDFDocumentView(asset: asset).id(identity))
        case .localWeb: return AnyView(LocalDocumentView(asset: asset).id(identity))
        case .quickLook: return AnyView(QuickLookDocumentView(asset: asset).id(identity))
        case .metadata: return AnyView(MetadataAssetView(asset: asset).id(identity))
        }
    }
}
