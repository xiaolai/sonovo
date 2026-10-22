enum AssetViewerRoute: Equatable, Sendable {
    case image
    case pdf
    case localWeb
    case quickLook
    case metadata
}

/// The single routing table for document-like assets. Image and media kinds
/// have their own viewers; this decides the rest.
enum ViewerRouter {
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "heic", "heif", "tif",
        "tiff", "webp", "avif", "dng", "cr3", "arw", "nef", "exr",
        "hdr"
    ]

    static let webExtensions: Set<String> = ["svg", "html", "htm"]

    static let quickLookExtensions: Set<String> = [
        "docx", "rtf", "odt", "pages", "key", "pptx", "xlsx",
        "csv", "tsv", "fountain", "fdx",
        "otio", "edl", "fcpxml", "epub", "psd", "psb", "ai", "eps"
    ]

    static func route(forExtension fileExtension: String) -> AssetViewerRoute {
        let ext = fileExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if webExtensions.contains(ext) { return .localWeb }
        if imageExtensions.contains(ext) { return .image }
        if quickLookExtensions.contains(ext) { return .quickLook }
        return .metadata
    }

    static func route(for asset: ProjectAsset) -> AssetViewerRoute {
        route(forExtension: asset.fileExtension)
    }
}
