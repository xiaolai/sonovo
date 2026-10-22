import Foundation
import XCTest
@testable import Sonovo

final class ProjectPathPolicyTests: XCTestCase {
    func testIgnoredDirectoriesAreCheckedByRole() throws {
        let support = CodeTestSupport()
        defer { support.tearDown() }
        let root = try support.makeRoot(files: [
            "safe.swift": Data("let a = 1\n".utf8),
            "Caches": Data("a regular file named like a cache\n".utf8),
            "DerivedData/inside.swift": Data("let b = 2\n".utf8),
            "node_modules/pkg/index.js": Data("x\n".utf8)
        ])

        XCTAssertTrue(
            ProjectPathPolicy.isAllowed(
                root.appendingPathComponent("Caches"),
                in: root
            ),
            "a regular file named Caches is not an ignored directory"
        )
        XCTAssertFalse(
            ProjectPathPolicy.isAllowed(
                root.appendingPathComponent("DerivedData/inside.swift"),
                in: root
            )
        )
        XCTAssertFalse(
            ProjectPathPolicy.isAllowed(
                root.appendingPathComponent("node_modules/pkg/index.js"),
                in: root
            )
        )
        XCTAssertTrue(
            ProjectPathPolicy.isAllowed(
                root.appendingPathComponent("safe.swift"),
                in: root
            )
        )
    }

    func testOutsideRootPathsAreRefused() throws {
        let support = CodeTestSupport()
        defer { support.tearDown() }
        let root = try support.makeRoot(files: [
            "safe.swift": Data("let a = 1\n".utf8)
        ])
        let other = try support.makeRoot(files: [
            "other.swift": Data("let b = 2\n".utf8)
        ])
        XCTAssertFalse(
            ProjectPathPolicy.isAllowed(
                other.appendingPathComponent("other.swift"),
                in: root
            )
        )
    }
}
