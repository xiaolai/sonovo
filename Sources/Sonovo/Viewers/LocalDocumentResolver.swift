import Foundation

/// Serves one local document and its sibling resources through a custom
/// scheme. The document directory is the root; canonical containment and an
/// extension allowlist decide what exists. JavaScript is never allowed.
struct LocalDocumentResolver: Sendable {
    struct Resource: Equatable, Sendable {
        let url: URL
        let mimeType: String
        /// Identity captured while validating. The handler compares it with
        /// the opened descriptor so a path swapped between validation and
        /// open cannot be served.
        let fileDevice: dev_t
        let fileInode: ino_t
    }

    enum Outcome: Equatable, Sendable {
        case file(Resource)
        case badRequest
        case forbidden
        case notFound
        case unsupportedType
    }

    static let scheme = "sonovo-doc"
    static let host = "local"
    static let routePath = "/doc/"

    static let servedExtensions: Set<String> = [
        "svg", "html", "htm", "css", "png", "jpg", "jpeg", "gif",
        "webp", "avif", "heic", "tif", "tiff", "ttf", "otf", "woff",
        "woff2", "xml", "json"
    ]

    let root: URL

    /// Canonical root with a trailing slash. The scheme handler derives the
    /// relative path it opens through directory-relative descriptors.
    var canonicalRootPath: String {
        let path = root.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasSuffix("/") ? path : path + "/"
    }

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
              components.fragment == nil else {
            return .badRequest
        }
        // A query string does not change which file is addressed. Sibling
        // resources commonly use cache-busting suffixes such as ?v=2.

        let encodedPath = components.percentEncodedPath
        guard encodedPath.hasPrefix(Self.routePath) else {
            return .badRequest
        }
        let raw = encodedPath.dropFirst(Self.routePath.count)
        guard !raw.isEmpty else { return .badRequest }
        let pieces = raw.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !pieces.contains(where: \.isEmpty) else {
            return .badRequest
        }
        let decoded = pieces.compactMap(Self.decodeComponent)
        guard decoded.count == pieces.count else { return .forbidden }
        guard let last = decoded.last else { return .badRequest }

        let extensionName = last
            .split(separator: ".", omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? ""
        guard !extensionName.isEmpty,
              last != ".\(extensionName)" else {
            return .badRequest
        }

        let canonicalRoot = root.resolvingSymlinksInPath()
            .standardizedFileURL
        var target = canonicalRoot
        for component in decoded {
            target.appendPathComponent(component, isDirectory: false)
        }
        target = target.resolvingSymlinksInPath().standardizedFileURL

        // Validate the canonical target, not only the requested name: a
        // symlink named page.html can point at a hidden file or a type the
        // resolver would otherwise refuse to serve.
        guard isContained(target) else { return .forbidden }
        let targetExtension = target.pathExtension.lowercased()
        guard !targetExtension.isEmpty,
              Self.servedExtensions.contains(targetExtension) else {
            return .unsupportedType
        }
        let ext = targetExtension

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: target.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
            return .notFound
        }
        var info = stat()
        let statResult = target.withUnsafeFileSystemRepresentation { path in
            path.map { stat($0, &info) } ?? -1
        }
        guard statResult == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            return .notFound
        }
        return .file(
            Resource(
                url: target,
                mimeType: Self.mimeType(for: ext),
                fileDevice: info.st_dev,
                fileInode: info.st_ino
            )
        )
    }

    /// Checks that a canonical path stays inside the root and does not
    /// address a hidden component.
    private func isContained(_ url: URL) -> Bool {
        let canonicalRoot = root.resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPath = canonicalRoot.path.hasSuffix("/")
            ? canonicalRoot.path
            : canonicalRoot.path + "/"
        guard url.path.hasPrefix(rootPath) else { return false }
        let components = url.path
            .dropFirst(rootPath.count)
            .split(separator: "/")
        return !components.contains(where: { $0.hasPrefix(".") })
    }

    /// Re-checks a descriptor the handler has just opened. A path swapped
    /// for a symlink between `resolve` and `open` either canonicalizes
    /// outside the root here or no longer matches the opened inode.
    func revalidates(
        _ resource: Resource,
        device: dev_t,
        inode: ino_t
    ) -> Bool {
        let canonical = resource.url.resolvingSymlinksInPath()
            .standardizedFileURL
        guard isContained(canonical) else { return false }
        let ext = canonical.pathExtension.lowercased()
        guard !ext.isEmpty,
              Self.servedExtensions.contains(ext) else {
            return false
        }
        var info = stat()
        let result = canonical.withUnsafeFileSystemRepresentation { path in
            path.map { stat($0, &info) } ?? -1
        }
        return result == 0
            && (info.st_mode & S_IFMT) == S_IFREG
            && info.st_dev == device
            && info.st_ino == inode
    }

    static func documentURL(fileName: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = routePath + fileName
        return components.url
    }

    /// The navigation delegate allows exactly the document route. Anything
    /// else — remote, `file:`, another host, another path — is cancelled.
    static func isDocumentNavigation(_ url: URL) -> Bool {
        url.scheme == scheme
            && url.host == host
            && url.path.hasPrefix(routePath)
    }

    static func mimeType(for fileExtension: String) -> String {
        switch fileExtension {
        case "svg": "image/svg+xml"
        case "html", "htm": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "avif": "image/avif"
        case "heic": "image/heic"
        case "tif", "tiff": "image/tiff"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "xml": "application/xml; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        default: "application/octet-stream"
        }
    }

    static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src 'none'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: blob:",
        "font-src 'self' data:",
        "connect-src 'none'",
        "frame-src 'none'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'none'"
    ].joined(separator: "; ")

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
}
