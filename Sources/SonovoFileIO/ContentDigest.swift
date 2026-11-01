import CryptoKit
import Foundation

package enum ContentDigest {
    package static func hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
