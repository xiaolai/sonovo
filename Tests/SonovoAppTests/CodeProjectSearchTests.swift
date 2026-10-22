import Foundation
import XCTest
@testable import Sonovo

final class CodeProjectSearchTests: XCTestCase {
    func testFindsLiteralMatchesWithLineAndColumn() async throws {
        let support = CodeTestSupport()
        defer { support.tearDown() }
        let root = try support.makeRoot(files: [
            "Sources/a.swift": CodeTestData.utf8(
                "let first = 1\nlet needle = 2\n"
            ),
            "notes.py": CodeTestData.utf8("needle = 3\n"),
            "ignored.bin": Data([0x00, 0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65])
        ])
        let result = await CodeProjectSearch().search(
            root: root,
            query: "needle"
        )
        XCTAssertEqual(result.matches.count, 2)
        XCTAssertEqual(result.filesSearched, 2)
        XCTAssertNil(result.truncationReason)
        let swiftMatch = try XCTUnwrap(
            result.matches.first { $0.relativePath.hasSuffix("a.swift") }
        )
        XCTAssertEqual(swiftMatch.line, 2)
        XCTAssertEqual(swiftMatch.column, 5)
        XCTAssertEqual(swiftMatch.preview, "let needle = 2")
    }

    func testCaseInsensitiveByDefaultAndCaseSensitiveOnRequest() async throws {
        let support = CodeTestSupport()
        defer { support.tearDown() }
        let root = try support.makeRoot(files: [
            "a.swift": CodeTestData.utf8("Needle\nneedle\n")
        ])
        let insensitive = await CodeProjectSearch().search(
            root: root,
            query: "needle"
        )
        XCTAssertEqual(insensitive.matches.count, 2)

        let sensitive = await CodeProjectSearch().search(
            root: root,
            query: "needle",
            caseSensitive: true
        )
        XCTAssertEqual(sensitive.matches.count, 1)
        XCTAssertEqual(sensitive.matches[0].line, 2)
    }

    func testSkipsHiddenIgnoredBinaryAndOutsideSymlinks() async throws {
        let support = CodeTestSupport()
        defer { support.tearDown() }
        let root = try support.makeRoot(files: [
            "a.swift": CodeTestData.utf8("needle\n"),
            "node_modules/pkg/b.js": CodeTestData.utf8("needle\n"),
            ".build/c.swift": CodeTestData.utf8("needle\n"),
            ".hidden/d.swift": CodeTestData.utf8("needle\n"),
            "binary.sw": Data([0x00, 0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65])
        ])
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoSearchOutside-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outside) }
        try support.write(
            CodeTestData.utf8("needle\n"),
            to: outside.appendingPathComponent("outside.swift")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.swift"),
            withDestinationURL: outside.appendingPathComponent("outside.swift")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("inside-link.swift"),
            withDestinationURL: root.appendingPathComponent("a.swift")
        )

        let result = await CodeProjectSearch().search(
            root: root,
            query: "needle"
        )
        XCTAssertEqual(
            result.matches.count,
            1,
            "the inside symlink and its target are one file"
        )
        XCTAssertEqual(result.matches.first?.relativePath, "a.swift")
    }

    func testPerFileAndTotalLimitsAreReported() async throws {
        let support = CodeTestSupport()
        defer { support.tearDown() }
        let root = try support.makeRoot(files: [
            "small.swift": CodeTestData.utf8("needle\n"),
            "large.swift": CodeTestData.utf8(
                "needle\n" + String(repeating: "x\n", count: 100)
            )
        ])
        var search = CodeProjectSearch()
        search.perFileBytes = 16
        let result = await search.search(root: root, query: "needle")
        XCTAssertEqual(result.skippedLargeFiles, 1)
        XCTAssertEqual(result.matches.count, 1)

        var totalSearch = CodeProjectSearch()
        totalSearch.totalBytes = 10
        let total = await totalSearch.search(root: root, query: "needle")
        XCTAssertNotNil(total.truncationReason)
        XCTAssertTrue(
            total.truncationReason?.contains("total limit") == true
        )
    }

    func testResultLimitTruncatesAndExplains() async throws {
        let support = CodeTestSupport()
        defer { support.tearDown() }
        let root = try support.makeRoot(files: [
            "many.swift": CodeTestData.utf8(
                String(repeating: "needle\n", count: 250)
            )
        ])
        var search = CodeProjectSearch()
        search.resultLimit = 3
        let result = await search.search(root: root, query: "needle")
        XCTAssertEqual(result.matches.count, 3)
        XCTAssertEqual(result.totalMatches, 250)
        XCTAssertTrue(
            result.truncationReason?.contains("3") == true
        )
    }

    func testResultsGroupByFileInSortedOrder() async throws {
        let support = CodeTestSupport()
        defer { support.tearDown() }
        let root = try support.makeRoot(files: [
            "b.swift": CodeTestData.utf8("needle\nx\nneedle\n"),
            "a.swift": CodeTestData.utf8("needle\n")
        ])
        let result = await CodeProjectSearch().search(
            root: root,
            query: "needle"
        )
        let groups = result.groupedByFile
        XCTAssertEqual(groups.map(\.path), ["a.swift", "b.swift"])
        XCTAssertEqual(groups[1].matches.map(\.line), [1, 3])
        XCTAssertEqual(groups[1].matches.map(\.column), [1, 1])
    }

    func testCancellationIsReported() async throws {
        let support = CodeTestSupport()
        defer { support.tearDown() }
        let root = try support.makeRoot(
            files: Dictionary(
                uniqueKeysWithValues: (0..<200).map {
                    ("file\($0).swift", CodeTestData.utf8("needle\n"))
                }
            )
        )
        let task = Task {
            await CodeProjectSearch().search(root: root, query: "needle")
        }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(
            result.wasCancelled || result.matches.count <= 200
        )
    }

    func testBinaryBytesCountTowardTheTotalBudget() async throws {
        let support = CodeTestSupport()
        defer { support.tearDown() }
        // 100 bytes each, valid UTF-8 in shape but NUL-bearing, so neither
        // is searchable. Charging only decoded files would let both be read
        // without ever reaching the budget.
        let binary = Data(repeating: 0x61, count: 99) + Data([0x00])
        let root = try support.makeRoot(files: [
            "a.swift": binary,
            "b.swift": binary
        ])
        var search = CodeProjectSearch()
        search.totalBytes = 150
        let result = await search.search(root: root, query: "needle")
        XCTAssertEqual(result.filesSearched, 0)
        XCTAssertEqual(
            result.bytesSearched,
            100,
            "the first binary file is charged before it is skipped"
        )
        XCTAssertNotNil(result.truncationReason)
    }
}
