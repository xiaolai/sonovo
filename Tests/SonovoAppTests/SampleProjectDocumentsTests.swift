import Foundation
import XCTest
@testable import Sonovo

final class SampleProjectDocumentsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoSampleProject-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Source", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        super.tearDown()
    }

    func testCopiesOnFirstUseAndNeverOverwritesEdits() throws {
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let destination = root.appendingPathComponent(
            "Dest/Project",
            isDirectory: true
        )
        try Data("original".utf8).write(
            to: source.appendingPathComponent("tidewater-script.md")
        )
        let project = SampleProjectDocuments(
            sourceDirectory: source,
            destinationDirectory: destination
        )

        let first = try project.documentURL(named: "tidewater-script.md")
        XCTAssertEqual(
            try String(contentsOf: first, encoding: .utf8),
            "original"
        )
        try Data("edited".utf8).write(to: first)

        let second = try project.documentURL(named: "tidewater-script.md")
        XCTAssertEqual(second, first)
        XCTAssertEqual(
            try String(contentsOf: second, encoding: .utf8),
            "edited",
            "A later launch must not replace the user's copy"
        )
    }

    func testMissingSampleIsReported() {
        let project = SampleProjectDocuments(
            sourceDirectory: root.appendingPathComponent(
                "Source",
                isDirectory: true
            ),
            destinationDirectory: root.appendingPathComponent(
                "Dest",
                isDirectory: true
            )
        )
        XCTAssertThrowsError(try project.documentURL(named: "missing.md")) {
            XCTAssertEqual(
                $0 as? SampleDocumentError,
                .sourceUnavailable("missing.md")
            )
        }
    }
}
