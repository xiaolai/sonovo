import AppKit
import PDFKit
import XCTest
@testable import Sonovo

@MainActor
final class PDFDocumentModelTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() {
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
        files = []
        super.tearDown()
    }

    func testLoadsPagesAndSearchesText() async throws {
        let url = try makePDF(text: "Hello PDF")
        let model = PDFDocumentModel(url: url)
        await model.load()

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.pageCount, 1)
        let helloCount = await model.search("Hello")
        XCTAssertEqual(helloCount, 1)
        XCTAssertNotNil(model.currentSelection)
        let missingCount = await model.search("missing")
        XCTAssertEqual(missingCount, 0)
    }

    func testPasswordProtectedPDFReportsLockedState() async throws {
        let url = try makeLockedPDF(password: "sonovo")
        let model = PDFDocumentModel(url: url)
        await model.load()

        XCTAssertEqual(model.state, .locked)
        XCTAssertFalse(model.unlock(password: "wrong"))
        XCTAssertEqual(model.state, .locked)
        XCTAssertTrue(model.unlock(password: "sonovo"))
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.pageCount, 1)
    }

    func testInvalidPDFFails() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SonovoBad-\(UUID().uuidString).pdf")
        files.append(url)
        try Data("not a pdf".utf8).write(to: url)

        let model = PDFDocumentModel(url: url)
        await model.load()
        guard case .failed = model.state else {
            return XCTFail("Expected a failure, got \(model.state)")
        }
    }

    func testSearchStopsAtTheResultBudget() async throws {
        let url = try makePDF(text: "a a a a a a a a a")
        let model = PDFDocumentModel(url: url)
        await model.load()
        model.maximumSearchResults = 3

        let count = await model.search("a")
        XCTAssertEqual(count, 3)
        XCTAssertTrue(model.searchTruncated)
    }

    func testExactlyFillingTheBudgetIsNotTruncation() async throws {
        let url = try makePDF(text: "a a a")
        let model = PDFDocumentModel(url: url)
        await model.load()
        model.maximumSearchResults = 3

        let count = await model.search("a")
        XCTAssertEqual(count, 3)
        XCTAssertFalse(model.searchTruncated)
    }

    // MARK: - Helpers

    private func makePDF(text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoPDF-\(UUID().uuidString).pdf"
            )
        files.append(url)
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 300)
        guard let context = CGContext(
            url as CFURL,
            mediaBox: &mediaBox,
            nil
        ) else {
            throw PDFTestError.context
        }
        context.beginPDFPage(nil)
        let graphics = NSGraphicsContext(
            cgContext: context,
            flipped: false
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 24)
            ]
        ).draw(at: NSPoint(x: 40, y: 160))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private func makeLockedPDF(password: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoPDF-\(UUID().uuidString).pdf"
            )
        files.append(url)
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 300)
        let options: [CFString: Any] = [
            kCGPDFContextUserPassword: password,
            kCGPDFContextOwnerPassword: password + "-owner",
            kCGPDFContextEncryptionKeyLength: 128
        ]
        guard let context = CGContext(
            url as CFURL,
            mediaBox: &mediaBox,
            options as CFDictionary
        ) else {
            throw PDFTestError.context
        }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return url
    }
}

private enum PDFTestError: Error {
    case context
}
