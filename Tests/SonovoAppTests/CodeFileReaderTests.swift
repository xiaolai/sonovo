import XCTest
@testable import Sonovo

final class CodeFileReaderTests: XCTestCase {
    private let reader = CodeFileReader()

    func testDecodesUTF8LFCRLFAndBOM() throws {
        let support = CodeTestSupport()
        defer { support.tearDown() }
        let root = try support.makeRoot(
            files: [
                "lf.swift": CodeTestData.utf8("let a = 1\nlet b = 2\n"),
                "crlf.swift": CodeTestData.crlf("let a = 1\nlet b = 2\n"),
                "bom.swift": CodeTestData.bom("let a = 1\n")
            ]
        )

        guard case .loaded(let lf) = try reader.read(
            url: root.appendingPathComponent("lf.swift")
        ) else {
            return XCTFail("LF did not load")
        }
        XCTAssertEqual(lf.contents.lineEnding, .lf)
        XCTAssertFalse(lf.contents.hasBOM)
        XCTAssertEqual(lf.contents.canonicalText, "let a = 1\nlet b = 2\n")
        XCTAssertNil(lf.readOnlyReason)

        guard case .loaded(let crlf) = try reader.read(
            url: root.appendingPathComponent("crlf.swift")
        ) else {
            return XCTFail("CRLF did not load")
        }
        XCTAssertEqual(crlf.contents.lineEnding, .crlf)
        XCTAssertFalse(crlf.contents.hadMixedLineEndings)
        XCTAssertNil(crlf.readOnlyReason)

        guard case .loaded(let bom) = try reader.read(
            url: root.appendingPathComponent("bom.swift")
        ) else {
            return XCTFail("BOM did not load")
        }
        XCTAssertTrue(bom.contents.hasBOM)
        XCTAssertEqual(bom.contents.canonicalText, "let a = 1\n")
        XCTAssertNil(bom.readOnlyReason)
    }

    func testMixedLineEndingsAndLoneCRAreReadOnly() throws {
        let support = CodeTestSupport()
        defer { support.tearDown() }
        let root = try support.makeRoot(
            files: [
                "mixed.swift": CodeTestData.utf8("a\r\nb\nc\n"),
                "lone.swift": CodeTestData.utf8("a\rb\rc")
            ]
        )

        guard case .loaded(let mixed) = try reader.read(
            url: root.appendingPathComponent("mixed.swift")
        ) else {
            return XCTFail("mixed did not load")
        }
        XCTAssertTrue(mixed.contents.hadMixedLineEndings)
        XCTAssertEqual(mixed.readOnlyReason, .mixedLineEndings)

        guard case .loaded(let lone) = try reader.read(
            url: root.appendingPathComponent("lone.swift")
        ) else {
            return XCTFail("lone CR did not load")
        }
        XCTAssertTrue(lone.hasLoneCarriageReturn)
        XCTAssertEqual(lone.readOnlyReason, .loneCarriageReturn)
    }

    func testUnsupportedEncodingsAreRefusedByName() throws {
        let support = CodeTestSupport()
        defer { support.tearDown() }
        let root = try support.makeRoot(
            files: [
                "le.swift": CodeTestData.utf16LE("let a = 1\n"),
                "be.swift": CodeTestData.utf16BE("let a = 1\n"),
                "latin.swift": CodeTestData.latin1("caf\u{00E9}\n"),
                "utf32.swift": Data(
                    [0xFF, 0xFE, 0x00, 0x00] + Array("a".utf16.flatMap {
                        [UInt8($0 & 0xFF), UInt8($0 >> 8)]
                    })
                )
            ]
        )

        guard case .refused(let le) = try reader.read(
            url: root.appendingPathComponent("le.swift")
        ) else { return XCTFail("UTF-16 LE was not refused") }
        XCTAssertEqual(le, .unsupportedEncoding("UTF-16 LE"))

        guard case .refused(let be) = try reader.read(
            url: root.appendingPathComponent("be.swift")
        ) else { return XCTFail("UTF-16 BE was not refused") }
        XCTAssertEqual(be, .unsupportedEncoding("UTF-16 BE"))

        guard case .refused(let latin) = try reader.read(
            url: root.appendingPathComponent("latin.swift")
        ) else { return XCTFail("Latin-1 was not refused") }
        XCTAssertEqual(latin, .unsupportedEncoding("this encoding"))

        guard case .refused(let utf32) = try reader.read(
            url: root.appendingPathComponent("utf32.swift")
        ) else { return XCTFail("UTF-32 was not refused") }
        XCTAssertEqual(utf32, .unsupportedEncoding("UTF-32 LE"))
    }

    func testBinaryIsRefusedAfterEncodingDetection() throws {
        let support = CodeTestSupport()
        defer { support.tearDown() }
        let root = try support.makeRoot(
            files: [
                "binary.swift": Data([0x00, 0x01, 0x02, 0x03]),
                "nul.swift": Data("let a = 1\n\u{0}".utf8)
            ]
        )
        for name in ["binary.swift", "nul.swift"] {
            guard case .refused(let refusal) = try reader.read(
                url: root.appendingPathComponent(name)
            ) else {
                return XCTFail("\(name) was not refused")
            }
            XCTAssertEqual(refusal, .binary, name)
        }
    }

    func testSizeThresholds() throws {
        let support = CodeTestSupport()
        defer { support.tearDown() }
        let editable = Data(repeating: 0x61, count: CodeLimits.editableBytes)
        let readOnly = Data(
            repeating: 0x61,
            count: CodeLimits.editableBytes + 1
        )
        let tooLarge = Data(
            repeating: 0x61,
            count: CodeLimits.maximumReadBytes + 1
        )
        let root = try support.makeRoot(
            files: [
                "editable.txt": editable,
                "readonly.txt": readOnly,
                "huge.txt": tooLarge
            ]
        )

        guard case .loaded(let small) = try reader.read(
            url: root.appendingPathComponent("editable.txt")
        ) else { return XCTFail("editable did not load") }
        XCTAssertNil(small.readOnlyReason)

        guard case .loaded(let medium) = try reader.read(
            url: root.appendingPathComponent("readonly.txt")
        ) else { return XCTFail("read-only size did not load") }
        XCTAssertEqual(
            medium.readOnlyReason,
            .size(byteCount: CodeLimits.editableBytes + 1)
        )

        guard case .refused(let refusal) = try reader.read(
            url: root.appendingPathComponent("huge.txt")
        ) else { return XCTFail("huge file was not refused") }
        guard case .tooLarge(let count) = refusal else {
            return XCTFail("expected tooLarge, got \(refusal)")
        }
        XCTAssertGreaterThan(count, Int64(CodeLimits.maximumReadBytes))
    }

    func testNineMegabyteFileIsRefused() throws {
        let support = CodeTestSupport()
        defer { support.tearDown() }
        let url = try support.makeRoot()
            .appendingPathComponent("nine.txt")
        try support.write(
            Data(repeating: 0x61, count: 9 * 1_024 * 1_024),
            to: url
        )
        guard case .refused(let refusal) = try reader.read(url: url) else {
            return XCTFail("a 9 MB file must be refused")
        }
        guard case .tooLarge(let count) = refusal else {
            return XCTFail("expected tooLarge, got \(refusal)")
        }
        XCTAssertGreaterThanOrEqual(count, 9 * 1_024 * 1_024)
    }

    func testGrowthDuringTheReadIsCutAtTheCap() throws {
        let support = CodeTestSupport()
        defer { support.tearDown() }
        // A file already above the cap exercises the same bounded read a file
        // that grows during the read takes: the reader never allocates more
        // than cap + 1 and never decodes the partial bytes.
        let url = try support.makeRoot()
            .appendingPathComponent("growing.txt")
        try support.write(
            Data(
                repeating: 0x61,
                count: CodeLimits.maximumReadBytes + 4_096
            ),
            to: url
        )
        guard case .refused(.tooLarge) = try reader.read(url: url) else {
            return XCTFail("a growing file must be refused")
        }
    }

    func testDecodeBoundedMatchesTheReadersRules() {
        // Conflict bytes go through the same validation as a fresh open, so
        // a reload cannot install text the reader would refuse.
        guard case .text(let text) = CodeFileReader.decodeBounded(
            CodeTestData.utf8("let a = 1\n")
        ) else {
            return XCTFail("valid UTF-8 must decode")
        }
        XCTAssertEqual(text.canonicalText, "let a = 1\n")

        guard case .refused(.binary) = CodeFileReader.decodeBounded(
            Data([0x61, 0x00, 0x62])
        ) else {
            return XCTFail("a NUL-bearing UTF-8 file is binary")
        }
        guard case .refused(.unsupportedEncoding(let name)) =
            CodeFileReader.decodeBounded(CodeTestData.utf16LE("hi")) else {
            return XCTFail("UTF-16 must be refused by name")
        }
        XCTAssertEqual(name, "UTF-16 LE")
        guard case .refused = CodeFileReader.decodeBounded(
            CodeTestData.latin1("caf\u{E9}")
        ) else {
            return XCTFail("invalid UTF-8 must be refused")
        }
    }
}
