import Foundation
import SonovoFileIO
private final class ModelResourceAnchor: NSObject {}

/// One place that knows where the bundled viewer lives. Tests assert against
/// the same root the web view serves, so a missing resource fails loudly.
package enum ModelViewerResources {
    package static var root: URL? {
        ResourceBundleLocator.find(named: "Sonovo_SonovoModel3DFeature.bundle", relativeTo: Bundle(for: ModelResourceAnchor.self))?.url(forResource: "ModelViewer", withExtension: nil)
    }

    package static var indexHTML: URL? {
        root?.appendingPathComponent("index.html")
    }

    package static var conversionScript: URL? {
        root?.appendingPathComponent("scripts/convert_blend.py")
    }
}
