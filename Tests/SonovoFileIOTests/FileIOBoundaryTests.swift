import Foundation
import XCTest
@testable import SonovoFileIO

final class FileIOBoundaryTests: XCTestCase {
    private func withFile(_ bytes: Data, _ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture")
        try bytes.write(to: url)
        try body(url)
    }

    func testBoundedReaderTakesCallerByteAndLineLimits() throws {
        try withFile(Data("a\nb\n".utf8)) { url in
            XCTAssertEqual(try BoundedFileReader.read(url, maximumBytes: 4, maximumLines: 2), Data("a\nb\n".utf8))
            XCTAssertThrowsError(try BoundedFileReader.read(url, maximumBytes: 3, maximumLines: 2)) {
                XCTAssertEqual($0 as? FileReadError, .fileTooLarge(byteCount: 4))
            }
            XCTAssertThrowsError(try BoundedFileReader.read(url, maximumBytes: 4, maximumLines: 1)) {
                XCTAssertEqual($0 as? FileReadError, .tooManyLines(2))
            }
        }
    }

    func testAtomicSaveRefusesExactByteMismatchAndKeepsDestination() throws {
        let baseline = Data([0xEF, 0xBB, 0xBF]) + Data("line\r\n".utf8)
        try withFile(baseline) { url in
            let request = SaveRequest(
                documentID: UUID(), identityGeneration: 0, sourceRevision: 0,
                destination: url, expectedDisk: DiskSnapshot(bytes: Data("line\n".utf8)),
                data: Data("replacement\n".utf8), mode: .automatic
            )
            XCTAssertThrowsError(try AtomicFileStore().save(request)) {
                guard case .diskChanged = $0 as? SaveError else { return XCTFail("expected exact-byte conflict: \($0)") }
            }
            XCTAssertEqual(try Data(contentsOf: url), baseline)
        }
    }

    func testMissingLeafUnderSymlinkUsesCanonicalAncestor() throws {
        try withFile(Data()) { url in
            let root = url.deletingLastPathComponent()
            let real = root.appendingPathComponent("real")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            XCTAssertEqual(
                FilePathPolicy.canonical(link.appendingPathComponent("missing/leaf")),
                real.resolvingSymlinksInPath().appendingPathComponent("missing/leaf")
            )
        }
    }
}
