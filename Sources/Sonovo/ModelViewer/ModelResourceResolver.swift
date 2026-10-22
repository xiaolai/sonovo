import Foundation

/// Maps `sonovo-model://local/...` requests onto the bundled viewer and the
/// selected model's directory. Pure and file-system-only, so every traversal
/// and allowlist rule is testable without WebKit.
struct ModelResourceResolver: Sendable {
    enum Route: String, Sendable {
        case viewer
        case asset
    }

    struct Resource: Equatable, Sendable {
        let url: URL
        let mimeType: String
        let route: Route
    }

    enum Outcome: Equatable, Sendable {
        case file(Resource)
        /// An allowed asset path that does not exist yet. The handler
        /// records the request so creating the sidecar later reloads the
        /// model.
        case missingAsset(URL)
        /// Malformed URL, wrong host, query, fragment, or empty component.
        case badRequest
        /// A valid-looking path that escapes its root or names a hidden file.
        case forbidden
        case notFound
        /// A file exists but its extension is not served on this route.
        case unsupportedType
    }

    static let scheme = "sonovo-model"
    static let host = "local"
    static let viewerPagePath = "/viewer/index.html"

    static let viewerExtensions: Set<String> = [
        "html", "js", "mjs", "css", "json", "wasm"
    ]

    static let assetExtensions: Set<String> = [
        "glb", "gltf", "bin", "stl", "obj", "mtl", "ply", "fbx", "3mf",
        "usdz", "usda", "usdc", "usd", "dae",
        "png", "jpg", "jpeg", "webp", "avif", "gif", "bmp", "tga", "dds",
        "ktx2", "basis", "hdr", "exr"
    ]

    let viewerRoot: URL
    let assetRoot: URL
    /// The file the workspace actually opened. A sniffed model may have no
    /// extension, which the extension allowlist would otherwise reject even
    /// though it is the selected primary asset.
    var primaryFile: URL? = nil

    func resolve(_ url: URL) -> Outcome {
        guard url.scheme == Self.scheme else { return .badRequest }
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return .badRequest
        }
        guard components.host == Self.host,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil else {
            return .badRequest
        }

        let encodedPath = components.percentEncodedPath
        guard encodedPath.hasPrefix("/") else { return .badRequest }

        let pieces = encodedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        // A leading slash produces one empty leading component. Any other
        // empty component means "//" or a trailing slash, neither of which
        // names a file.
        guard pieces.first?.isEmpty == true, pieces.count > 1 else {
            return .badRequest
        }
        let rawComponents = pieces.dropFirst()
        guard !rawComponents.contains(where: \.isEmpty) else {
            return .badRequest
        }

        let decoded = rawComponents.compactMap(Self.decodeComponent)
        guard decoded.count == rawComponents.count else {
            return .forbidden
        }

        guard let routeName = decoded.first,
              let route = Route(rawValue: routeName),
              decoded.count >= 2 else {
            return .badRequest
        }

        let fileComponents = Array(decoded.dropFirst())
        // Hidden path components are never served. The requested path and
        // the resolved target are checked separately: a visible symlink must
        // not expose a hidden file inside the root.
        guard !fileComponents.contains(where: { $0.hasPrefix(".") }) else {
            return .forbidden
        }
        guard let extensionName = fileComponents.last?
            .split(separator: ".", omittingEmptySubsequences: false)
            .last
            .map(String.init),
            !extensionName.isEmpty,
            fileComponents.last != ".\(extensionName)" else {
            return .badRequest
        }
        let fileExtension = extensionName.lowercased()

        let root = (route == .viewer ? viewerRoot : assetRoot)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var target = root
        for component in fileComponents {
            target.appendPathComponent(component, isDirectory: false)
        }
        target = target.resolvingSymlinksInPath().standardizedFileURL

        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target.path.hasPrefix(rootPath) else {
            return .forbidden
        }

        let relative = String(target.path.dropFirst(rootPath.count))
        guard !relative.split(separator: "/").contains(where: {
            $0.hasPrefix(".")
        }) else {
            return .forbidden
        }
        let resolvedExtension = target.pathExtension.lowercased()
        let allowedExtension = route == .viewer
            ? Self.viewerExtensions.contains(resolvedExtension)
            : Self.assetExtensions.contains(resolvedExtension)
        let isPrimaryFile = route == .asset
            && primaryFile.map {
                $0.resolvingSymlinksInPath().standardizedFileURL.path
                    == target.path
            } == true
        guard allowedExtension || isPrimaryFile else {
            return .unsupportedType
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: target.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
            // An allowed asset path can name a sidecar the model declares
            // but that does not exist (yet). Record that request so its
            // creation is visible to the resource-revision check.
            return route == .asset ? .missingAsset(target) : .notFound
        }

        return .file(
            Resource(
                url: target,
                mimeType: Self.mimeType(forExtension: fileExtension),
                route: route
            )
        )
    }

    private static func decodeComponent(_ encoded: Substring) -> String? {
        let lowered = encoded.lowercased()
        for forbidden in ["%00", "%2f", "%5c"] where lowered.contains(forbidden) {
            return nil
        }
        guard let decoded = String(encoded).removingPercentEncoding,
              !decoded.isEmpty,
              decoded != ".",
              decoded != "..",
              !decoded.hasPrefix("."),
              !decoded.contains("/"),
              !decoded.contains("\\"),
              !decoded.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return nil
        }
        return decoded
    }

    static func mimeType(forExtension fileExtension: String) -> String {
        switch fileExtension {
        case "html": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "wasm": "application/wasm"
        case "glb": "model/gltf-binary"
        case "gltf": "model/gltf+json; charset=utf-8"
        case "stl": "model/stl"
        case "3mf": "model/3mf"
        case "usdz": "model/vnd.usdz+zip"
        case "usda": "model/vnd.usda"
        case "usdc", "usd": "model/vnd.usd"
        case "dae": "model/vnd.collada+xml"
        case "obj", "mtl": "text/plain; charset=utf-8"
        case "ply": "application/octet-stream"
        case "fbx", "bin": "application/octet-stream"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "avif": "image/avif"
        case "gif": "image/gif"
        case "bmp": "image/bmp"
        case "tga": "image/x-tga"
        case "dds": "image/vnd-ms.dds"
        case "ktx2": "image/ktx2"
        case "basis": "application/octet-stream"
        case "hdr": "image/vnd.radiance"
        case "exr": "image/x-exr"
        default: "application/octet-stream"
        }
    }

    /// Builds an asset URL for a path relative to the model's directory.
    /// A sidecar may live in a subdirectory (`mtllib materials/custom.mtl`),
    /// so the relative path, not just the last component, has to survive.
    /// Components are percent-encoded here and re-validated by `resolve`.
    static func assetURL(relativePath: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/asset/" + relativePath
        return components.url
    }

    static func viewerURL() -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = viewerPagePath
        return components.url
    }
}
