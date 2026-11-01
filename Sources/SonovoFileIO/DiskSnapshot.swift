import CryptoKit
import Foundation

/// A byte-for-byte snapshot of the file an edit was based on.
public struct DiskSnapshot: Sendable, Equatable {
    public let bytes: Data
    public let sha256: String

    public init(bytes: Data) {
        self.bytes = bytes
        self.sha256 = ContentDigest.hex(bytes)
    }

    public var byteCount: Int { bytes.count }
}
