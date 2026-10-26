import Foundation
import Testing
@testable import SonovoMDXKit

@Suite("MDX compile cache keys")
struct MDXCompileCacheKeyTests {
    @Test("The entry key is stable and content-addressed")
    func entryKeyStable() {
        let first = MDXCompileCacheKey.entryKey(
            entryID: "a.mdx",
            source: "# A\n"
        )
        let second = MDXCompileCacheKey.entryKey(
            entryID: "a.mdx",
            source: "# A\n"
        )
        let changed = MDXCompileCacheKey.entryKey(
            entryID: "a.mdx",
            source: "# A changed\n"
        )
        #expect(first == second)
        #expect(first != changed)
        #expect(first.count == 64)
    }

    @Test("The toolchain version participates in the key")
    func toolchainVersion() {
        let current = MDXCompileCacheKey.entryKey(
            entryID: "a.mdx",
            source: "# A\n"
        )
        let vendored = MDXCompileCacheKey.entryKey(
            entryID: "a.mdx",
            source: "# A\n",
            toolchainVersion: "older"
        )
        #expect(current != vendored)
    }

    @Test("The graph key does not depend on dictionary order")
    func graphKeyOrderIndependent() {
        let first = MDXSourceGraph(
            entryID: "entry.mdx",
            files: ["entry.mdx": "# E\n", "a.jsx": "a"]
        )
        let second = MDXSourceGraph(
            entryID: "entry.mdx",
            files: ["a.jsx": "a", "entry.mdx": "# E\n"]
        )
        #expect(
            MDXCompileCacheKey.graphKey(first)
                == MDXCompileCacheKey.graphKey(second)
        )
    }

    @Test("Any file or the entry name changes the graph key")
    func graphKeyCoversEveryFile() {
        let base = MDXSourceGraph(
            entryID: "entry.mdx",
            files: ["entry.mdx": "# E\n", "a.jsx": "a"]
        )
        let changedDependency = MDXSourceGraph(
            entryID: "entry.mdx",
            files: ["entry.mdx": "# E\n", "a.jsx": "b"]
        )
        let changedEntry = MDXSourceGraph(
            entryID: "other.mdx",
            files: ["entry.mdx": "# E\n", "a.jsx": "a"]
        )
        let baseKey = MDXCompileCacheKey.graphKey(base)
        #expect(baseKey != MDXCompileCacheKey.graphKey(changedDependency))
        #expect(baseKey != MDXCompileCacheKey.graphKey(changedEntry))
    }

    @Test("The content hash is a SHA-256 hex digest")
    func contentHash() {
        let hash = MDXCompileCacheKey.contentHash("hello")
        #expect(hash.count == 64)
        #expect(
            hash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }
}
