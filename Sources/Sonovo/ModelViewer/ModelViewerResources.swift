import Foundation

/// One place that knows where the bundled viewer lives. Tests assert against
/// the same root the web view serves, so a missing resource fails loudly.
enum ModelViewerResources {
    static var root: URL? {
        Bundle.module.url(forResource: "ModelViewer", withExtension: nil)
    }

    static var indexHTML: URL? {
        root?.appendingPathComponent("index.html")
    }

    static var conversionScript: URL? {
        root?.appendingPathComponent("scripts/convert_blend.py")
    }
}
