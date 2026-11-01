import Foundation
import SonovoFileIO
private final class MDXResourceAnchor: NSObject {}
package enum MDXBundledResources {
    package static var bundle: Bundle? {
        ResourceBundleLocator.find(named: "Sonovo_SonovoMDXKit.bundle", relativeTo: Bundle(for: MDXResourceAnchor.self))
    }
}
