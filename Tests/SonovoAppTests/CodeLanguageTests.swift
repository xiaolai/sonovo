import XCTest
@testable import Sonovo

final class CodeLanguageTests: XCTestCase {
    func testClassifiesEveryListedExtension() {
        for fileExtension in CodeLanguage.extensions {
            XCTAssertNotNil(
                CodeLanguage.language(forExtension: fileExtension),
                fileExtension
            )
            if let language = CodeLanguage.language(
                forExtension: fileExtension
            ) {
                XCTAssertNotNil(
                    ProjectScanner.kind(forFilename: "file.\(fileExtension)")
                )
                XCTAssertEqual(
                    ProjectScanner.kind(
                        forFilename: "file.\(fileExtension)"
                    ),
                    .code,
                    fileExtension
                )
                _ = language
            }
        }
    }

    func testSpecialFilenamesAreCodeWithoutExtensions() {
        XCTAssertEqual(
            CodeLanguage.language(forFilename: "Makefile"),
            .makefile
        )
        XCTAssertEqual(
            CodeLanguage.language(forFilename: "Dockerfile"),
            .dockerfile
        )
        XCTAssertEqual(
            CodeLanguage.language(forFilename: "Rakefile"),
            .rakefile
        )
        XCTAssertEqual(
            CodeLanguage.language(forFilename: "Gemfile"),
            .gemfile
        )
        XCTAssertEqual(ProjectScanner.kind(forFilename: "Makefile"), .code)
        XCTAssertEqual(
            ProjectScanner.kind(forFilename: "Dockerfile.debug"),
            .code
        )
    }

    func testDedicatedViewersKeepTheirExtensions() {
        XCTAssertNil(CodeLanguage.language(forFilename: "notes.md"))
        XCTAssertNil(CodeLanguage.language(forFilename: "page.html"))
        XCTAssertNil(CodeLanguage.language(forFilename: "table.csv"))
        XCTAssertNil(CodeLanguage.language(forFilename: "captions.srt"))
        XCTAssertNil(CodeLanguage.language(forFilename: "README"))

        XCTAssertEqual(
            ProjectScanner.kind(forFilename: "notes.md"),
            .script
        )
        XCTAssertEqual(
            ProjectScanner.kind(forFilename: "page.html"),
            .html
        )
        XCTAssertEqual(
            ProjectScanner.kind(forFilename: "table.csv"),
            .document
        )
        XCTAssertNil(ProjectScanner.kind(forFilename: "README"))
    }

    func testDotfilesAndJSONCAreClassified() {
        XCTAssertEqual(
            CodeLanguage.language(forFilename: ".zshrc"),
            .shell
        )
        XCTAssertEqual(
            CodeLanguage.language(forFilename: ".bashrc"),
            .shell
        )
        XCTAssertEqual(
            CodeLanguage.language(forFilename: ".bash_profile"),
            .shell
        )
        XCTAssertEqual(
            CodeLanguage.language(forExtension: "jsonc"),
            .jsonc
        )
        XCTAssertEqual(
            ProjectScanner.kind(forFilename: ".zshrc"),
            .code
        )
    }

    func testPlainTextAndOutlineTiers() {
        XCTAssertEqual(
            CodeLanguage.language(forFilename: "notes.txt"),
            .plainText
        )
        XCTAssertEqual(
            CodeLanguage.language(forFilename: "run.log"),
            .plainText
        )
        XCTAssertFalse(CodeLanguage.plainText.supportsOutline)
        XCTAssertTrue(CodeLanguage.swift.supportsOutline)
        XCTAssertTrue(CodeLanguage.javascript.supportsOutline)
        XCTAssertTrue(CodeLanguage.typescript.supportsOutline)
        XCTAssertTrue(CodeLanguage.python.supportsOutline)
        XCTAssertTrue(CodeLanguage.shell.supportsOutline)
        XCTAssertFalse(CodeLanguage.rust.supportsOutline)
        XCTAssertFalse(CodeLanguage.json.supportsOutline)
    }

    func testProjectScannerGroupsCodeSeparately() throws {
        let support = CodeTestSupport()
        defer { support.tearDown() }
        let root = try support.makeRoot(
            files: [
                "main.swift": CodeTestData.utf8("let x = 1\n"),
                "script.md": CodeTestData.utf8("text\n"),
                "Makefile": CodeTestData.utf8("all:\n"),
                "notes.txt": CodeTestData.utf8("notes\n")
            ]
        )
        let result = ProjectScanner().scan(root: root)
        let byName = Dictionary(
            uniqueKeysWithValues: result.assets.map { ($0.name, $0.kind) }
        )
        XCTAssertEqual(byName["main.swift"], .code)
        XCTAssertEqual(byName["Makefile"], .code)
        XCTAssertEqual(byName["notes.txt"], .code)
        XCTAssertEqual(byName["script.md"], .script)
        XCTAssertEqual(
            result.groups.map(\.title),
            ["Documents", "Code"]
        )
    }
}
