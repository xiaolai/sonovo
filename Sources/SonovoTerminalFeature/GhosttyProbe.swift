import GhosttyKit

package enum GhosttyProbe {
    package static var version: String {
        let info = ghostty_info()
        guard let version = info.version else { return "unknown" }
        return String(cString: version)
    }
}
