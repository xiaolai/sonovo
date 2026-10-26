import CryptoKit
import Foundation

/// Content-addressed keys for compiled previews.
///
/// The entry key answers "is this document's source still the same?"; the
/// graph key covers every source in the resolved import graph. Both include
/// the toolchain version, so vendoring a new compiler invalidates old output
/// without a cache flush.
public enum MDXCompileCacheKey {
    public static func entryKey(
        entryID: String,
        source: String,
        toolchainVersion: String = MDXToolchain.version
    ) -> String {
        digest("\(toolchainVersion)\u{0}\(entryID)\u{0}\(source)")
    }

    public static func graphKey(
        _ graph: MDXSourceGraph,
        toolchainVersion: String = MDXToolchain.version
    ) -> String {
        var description = toolchainVersion
        description += "\u{0}\(graph.entryID)"
        for id in graph.files.keys.sorted() {
            description += "\u{0}\(id)\u{0}"
            description += graph.files[id] ?? ""
        }
        return digest(description)
    }

    public static func contentHash(_ text: String) -> String {
        digest(text)
    }

    private static func digest(_ text: String) -> String {
        let hash = SHA256.hash(data: Data(text.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
