import Foundation
import SonovoFileIO
private final class TerminalResourceAnchor: NSObject {}
package enum TerminalResources {
    package static var bundle: Bundle? {
        ResourceBundleLocator.find(named: "Sonovo_SonovoTerminalFeature.bundle", relativeTo: Bundle(for: TerminalResourceAnchor.self))
    }
}
