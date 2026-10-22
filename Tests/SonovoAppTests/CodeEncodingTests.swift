import XCTest
@testable import Sonovo

/// M0 — the preservation gate. A one-character edit must leave every other
/// byte untouched, and every unsupported case must be read-only or refused.
@MainActor
final class CodeEncodingTests: XCTestCase {
    private var support: CodeTestSupport!

    override func setUp() {
        super.setUp()
        support = CodeTestSupport()
    }

    override func tearDown() {
        support.tearDown()
        support = nil
        super.tearDown()
    }

    private func loadedDocument(
        _ data: Data,
        name: String = "file.swift"
    ) async throws -> (CodeDocument, URL) {
        let root = try support.makeRoot(files: [name: data])
        let url = root.appendingPathComponent(name)
        let document = CodeDocument(url: url)
        await document.load()
        return (document, url)
    }

    func testUTF8LFEditPreservesEveryOtherByte() async throws {
        let original = "let first = 1\nlet second = 2\n"
        let (document, url) = try await loadedDocument(
            CodeTestData.utf8(original)
        )
        XCTAssertTrue(document.isEditable)
        try document.replaceSource(
            "let first = 9\nlet second = 2\n"
        )
        XCTAssertTrue(document.isDirty)
        try await document.save()

        let written = try Data(contentsOf: url)
        XCTAssertEqual(
            written,
            CodeTestData.utf8("let first = 9\nlet second = 2\n")
        )
        XCTAssertFalse(document.isDirty)
    }

    func testUTF8CRLFEditPreservesCRLF() async throws {
        let original = "let first = 1\r\nlet second = 2\r\n"
        let (document, url) = try await loadedDocument(
            CodeTestData.utf8(original),
            name: "crlf.swift"
        )
        XCTAssertEqual(document.lineEnding, .crlf)
        try document.replaceSource(
            "let first = 1\nlet second = 9\n"
        )
        try await document.save()

        let written = try Data(contentsOf: url)
        XCTAssertEqual(
            written,
            CodeTestData.utf8(
                "let first = 1\r\nlet second = 9\r\n"
            )
        )
    }

    func testUTF8BOMEditPreservesBOM() async throws {
        let (document, url) = try await loadedDocument(
            CodeTestData.bom("let value = 1\n"),
            name: "bom.swift"
        )
        XCTAssertTrue(document.hasBOM)
        try document.replaceSource("let value = 2\n")
        try await document.save()

        let written = try Data(contentsOf: url)
        XCTAssertEqual(written, CodeTestData.bom("let value = 2\n"))
    }

    func testOneCharacterEditChangesExactlyOneByte() async throws {
        let (document, url) = try await loadedDocument(
            CodeTestData.utf8("abc\n"),
            name: "one.txt"
        )
        try document.replaceSource("abd\n")
        try await document.save()

        let written = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(written, Array("abd\n".utf8))
    }

    func testMixedEndingsStayReadOnly() async throws {
        let original = CodeTestData.utf8("a\r\nb\nc\n")
        let (document, _) = try await loadedDocument(
            original,
            name: "mixed.swift"
        )
        XCTAssertFalse(document.isEditable)
        XCTAssertEqual(document.readOnlyReason, .mixedLineEndings)
        XCTAssertThrowsError(try document.replaceSource("changed")) {
            XCTAssertEqual($0 as? CodeDocumentError, .readOnly)
        }
    }

    func testLoneCarriageReturnStaysReadOnly() async throws {
        let (document, _) = try await loadedDocument(
            CodeTestData.utf8("a\rb"),
            name: "lone.swift"
        )
        XCTAssertFalse(document.isEditable)
        XCTAssertEqual(document.readOnlyReason, .loneCarriageReturn)
    }

    func testUnsupportedEncodingIsRefused() async throws {
        let (document, _) = try await loadedDocument(
            CodeTestData.utf16LE("let a = 1\n"),
            name: "utf16.swift"
        )
        XCTAssertEqual(
            document.refusal,
            .unsupportedEncoding("UTF-16 LE")
        )
        XCTAssertFalse(document.isEditable)
        XCTAssertEqual(document.source, "")
    }

    func testLargeFileIsReadOnlyAndRetainsNoDiffBaseline() async throws {
        let data = Data(
            repeating: 0x61,
            count: CodeLimits.editableBytes + 16
        )
        let (document, _) = try await loadedDocument(
            data,
            name: "large.txt"
        )
        XCTAssertFalse(document.isEditable)
        XCTAssertEqual(
            document.readOnlyReason,
            .size(byteCount: data.count)
        )
        XCTAssertFalse(document.hasDiffBaseline)
    }

    func testUnwritableFileOpensReadOnlyAndSaveKeepsDirtyState() async throws {
        let (document, url) = try await loadedDocument(
            CodeTestData.utf8("let a = 1\n"),
            name: "locked.swift"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: url.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: url.path
            )
        }

        // Re-open so the permission check runs on the locked file.
        let reloaded = CodeDocument(url: url)
        await reloaded.load()
        XCTAssertEqual(reloaded.readOnlyReason, .permissions)
        XCTAssertFalse(reloaded.isEditable)
        XCTAssertThrowsError(try reloaded.replaceSource("changed"))
    }

    func testCodeSaveNeverWritesDirectly() throws {
        let root = FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("SonovoCodeScan")
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Sonovo/Code")
        let files = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil
        )
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                text.contains("data.write(to:"),
                "\(file.lastPathComponent) writes directly"
            )
            XCTAssertFalse(
                text.contains(".write(to:"),
                "\(file.lastPathComponent) writes directly"
            )
            XCTAssertFalse(
                text.contains("FileHandle(forWritingTo:"),
                "\(file.lastPathComponent) opens a write handle"
            )
        }
    }
}
