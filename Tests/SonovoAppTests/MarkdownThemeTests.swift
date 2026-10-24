import AppKit
import SwiftUI
import XCTest
@testable import Sonovo

@MainActor
final class MarkdownThemeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoReadingThemes-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        super.tearDown()
    }

    func testBuiltInThemesLoadWithNoWarnings() {
        let store = makeStore()
        let catalog = store.catalog()

        XCTAssertEqual(
            catalog.themes.map(\.id),
            ["paper", "book", "editorial", "draft"]
        )
        XCTAssertTrue(catalog.issues.isEmpty, "\(catalog.issues)")
        for theme in catalog.themes {
            XCTAssertTrue(
                theme.warnings.isEmpty,
                "\(theme.id): \(theme.warnings)"
            )
        }
    }

    /// Locks the default rendering the viewer shipped with. Changing these
    /// values changes every document that uses the default theme.
    func testPaperMatchesTheShippedDefaults() {
        let paper = makeStore().theme(id: "paper")

        XCTAssertEqual(paper.bodySize, 16.5)
        XCTAssertEqual(paper.bodyLineSpacing, 7)
        XCTAssertEqual(paper.measure, 660)
        XCTAssertEqual(paper.blockSpacing, 14)
        XCTAssertEqual(paper.pagePadding, 24)
        XCTAssertEqual(paper.codePadding, 12)
        XCTAssertEqual(paper.codeRadius, 12)
        XCTAssertEqual(paper.codeSize, 14)
        XCTAssertEqual(paper.codeLineSpacing, 4)
        XCTAssertEqual(paper.tableSize, 15)
        XCTAssertEqual(paper.captionSize, 12)
        XCTAssertEqual(paper.headingSizes, [32, 26, 22, 19, 17, 16])
        XCTAssertEqual(paper.headingTopPaddings, [30, 24, 18, 14, 10, 10])
        XCTAssertEqual(paper.bodyFont.design, .serif)
        XCTAssertEqual(paper.headingFont.design, .serif)
        XCTAssertEqual(paper.codeFont.design, .mono)
        XCTAssertEqual(paper.uiFont.design, .sans)
        XCTAssertTrue(paper.bodyFont.families.isEmpty)
        XCTAssertTrue(paper.headingFont.families.isEmpty)
        XCTAssertTrue(paper.codeFont.families.isEmpty)
        XCTAssertTrue(paper.uiFont.families.isEmpty)
    }

    func testBookInheritsPaperAndOverridesDeclaredValues() throws {
        let book = makeStore().theme(id: "book")

        XCTAssertEqual(book.bodySize, 17)
        XCTAssertEqual(book.codeSize, 13.5)
        XCTAssertEqual(
            book.codeLineSpacing,
            4,
            "codeLineSpacing is inherited from paper"
        )
        XCTAssertEqual(book.bodyFont.families.first, "Charter")
        XCTAssertEqual(book.bodyFont.design, .serif)
        XCTAssertEqual(book.uiFont.design, .sans)
        XCTAssertEqual(book.paragraphIndent, 1.2)
        XCTAssertEqual(
            book.light.warning,
            try XCTUnwrap(ThemeColor(hex: "#9A3412")),
            "the warning semantic is inherited from paper"
        )
        XCTAssertEqual(
            book.light.paper,
            try XCTUnwrap(ThemeColor(hex: "#FAF6EE"))
        )
        XCTAssertEqual(
            book.dark.paper,
            try XCTUnwrap(ThemeColor(hex: "#171411"))
        )
    }

    func testUserThemeExtendsPaperAndOverridesOnlyDeclaredValues() throws {
        try write(
            """
            {
              "schemaVersion": 1,
              "id": "big",
              "name": "Big",
              "typography": { "bodySize": 22, "measure": 800 },
              "colors": { "light": { "link": "#AA0000" } }
            }
            """,
            as: "big"
        )
        let theme = makeStore().theme(id: "big")

        XCTAssertEqual(theme.id, "big")
        XCTAssertEqual(theme.bodySize, 22)
        XCTAssertEqual(theme.measure, 800)
        XCTAssertEqual(theme.codeSize, 14, "paper's code size is inherited")
        XCTAssertEqual(
            theme.light.link,
            try XCTUnwrap(ThemeColor(hex: "#AA0000"))
        )
        XCTAssertEqual(
            theme.dark.link,
            try XCTUnwrap(ThemeColor(hex: "#0A84FF")),
            "an undeclared dark color is inherited"
        )
    }

    func testOutOfRangeValuesAreClampedAndReported() throws {
        try write(
            """
            {
              "schemaVersion": 1,
              "id": "huge",
              "name": "Huge",
              "typography": { "bodySize": 100, "measure": 100 }
            }
            """,
            as: "huge"
        )
        let theme = makeStore().theme(id: "huge")

        XCTAssertEqual(theme.bodySize, 24)
        XCTAssertEqual(theme.measure, 420)
        XCTAssertTrue(
            theme.warnings.contains { $0.contains("bodySize") }
        )
        XCTAssertTrue(
            theme.warnings.contains { $0.contains("measure") }
        )
    }

    func testInvalidColorIsRejectedAndFallsBack() throws {
        try write(
            """
            {
              "schemaVersion": 1,
              "id": "bad",
              "name": "Bad",
              "colors": { "light": { "link": "not-a-color" } }
            }
            """,
            as: "bad"
        )
        let store = makeStore()
        XCTAssertTrue(
            store.catalog().issues.contains { $0.contains("bad") }
        )
        XCTAssertEqual(store.theme(id: "bad").id, "paper")
    }

    func testCycleIsRejected() throws {
        try write(
            """
            {
              "schemaVersion": 1,
              "id": "a",
              "name": "A",
              "extends": "b"
            }
            """,
            as: "a"
        )
        try write(
            """
            {
              "schemaVersion": 1,
              "id": "b",
              "name": "B",
              "extends": "a"
            }
            """,
            as: "b"
        )
        let store = makeStore()
        XCTAssertTrue(
            store.catalog().issues.contains { $0.contains("loops") }
        )
        XCTAssertEqual(store.theme(id: "a").id, "paper")
    }

    func testMalformedJSONIsReported() throws {
        try write("{ this is not json", as: "broken")
        let store = makeStore()
        XCTAssertTrue(
            store.catalog().issues.contains { $0.contains("broken") }
        )
        XCTAssertEqual(store.theme(id: "broken").id, "paper")
    }

    func testIdentifierMustMatchItsFileName() throws {
        try write(
            """
            {
              "schemaVersion": 1,
              "id": "other",
              "name": "Other"
            }
            """,
            as: "mismatch"
        )
        let store = makeStore()
        XCTAssertTrue(
            store.catalog().issues.contains { $0.contains("mismatch") }
        )
    }

    func testMissingFontFallsBackToTheDesign() throws {
        try write(
            """
            {
              "schemaVersion": 1,
              "id": "missing-font",
              "name": "Missing Font",
              "typography": {
                "bodyFont": {
                  "families": ["No Such Font 12345"],
                  "design": "serif"
                }
              }
            }
            """,
            as: "missing-font"
        )
        let theme = makeStore().theme(id: "missing-font")

        XCTAssertNil(theme.bodyFont.resolvedFamily)
        // The call must not trap; the concrete Font is not comparable.
        _ = theme.bodyFont.font(size: 16)
    }

    func testDuplicateCreatesADerivedTheme() throws {
        let store = makeStore()
        let newID = try store.duplicateTheme(id: "paper")

        XCTAssertEqual(newID, "paper-copy")
        let duplicate = store.theme(id: newID)
        XCTAssertEqual(duplicate.name, "Paper Copy")
        XCTAssertEqual(duplicate.bodySize, store.theme(id: "paper").bodySize)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("\(newID).json").path
            )
        )
    }

    func testOverridesClampAndZeroMeansThemeDefault() {
        let paper = makeStore().theme(id: "paper")
        let overridden = paper.withOverrides(bodySize: 100, measure: 100)
        XCTAssertEqual(overridden.bodySize, 24)
        XCTAssertEqual(overridden.measure, 420)

        let unchanged = paper.withOverrides(bodySize: 0, measure: 0)
        XCTAssertEqual(unchanged.bodySize, paper.bodySize)
        XCTAssertEqual(unchanged.measure, paper.measure)
    }

    func testTransparentTextCannotPassContrast() throws {
        let transparent = try XCTUnwrap(ThemeColor(hex: "#00000000"))
        let white = try XCTUnwrap(ThemeColor(hex: "#FFFFFF"))
        XCTAssertEqual(
            transparent.contrast(with: white),
            1.0,
            accuracy: 0.01,
            "alpha must be composited before luminance"
        )
    }

    func testTranslucentInkIsReported() throws {
        try write(
            """
            {
              "schemaVersion": 1,
              "id": "ghost",
              "name": "Ghost",
              "colors": { "light": { "ink": "#00000000" } }
            }
            """,
            as: "ghost"
        )
        let theme = makeStore().theme(id: "ghost")
        XCTAssertTrue(
            theme.warnings.contains { $0.contains("text contrast") }
        )
    }

    func testWrongTypedExtendsIsRejected() throws {
        try write(
            """
            {
              "schemaVersion": 1,
              "id": "wrong-extends",
              "name": "Wrong Extends",
              "extends": 42
            }
            """,
            as: "wrong-extends"
        )
        let store = makeStore()
        XCTAssertTrue(
            store.catalog().issues.contains { $0.contains("wrong-extends") }
        )
        XCTAssertEqual(store.theme(id: "wrong-extends").id, "paper")
    }

    func testBaseIdentifierCannotEscapeTheThemesFolder() throws {
        try write(
            """
            {
              "schemaVersion": 1,
              "id": "escape",
              "name": "Escape",
              "extends": "../../etc/passwd"
            }
            """,
            as: "escape"
        )
        let store = makeStore()
        XCTAssertTrue(
            store.catalog().issues.contains { $0.contains("escape") }
        )
        XCTAssertEqual(store.theme(id: "escape").id, "paper")
        XCTAssertEqual(store.theme(id: "../../etc/passwd").id, "paper")
    }

    func testUserThemeCannotShadowABuiltIn() throws {
        try write(
            """
            { "schemaVersion": 1, "id": "paper", "name": "Fake Paper" }
            """,
            as: "paper"
        )
        let store = makeStore()
        XCTAssertTrue(
            store.catalog().issues.contains {
                $0.contains("cannot replace a built-in")
            }
        )
        XCTAssertEqual(store.theme(id: "paper").name, "Paper")
    }

    // MARK: - Helpers

    private func makeStore() -> MarkdownThemeStore {
        MarkdownThemeStore(userDirectory: directory)
    }

    private func write(_ json: String, as id: String) throws {
        try Data(json.utf8).write(
            to: directory.appendingPathComponent("\(id).json")
        )
    }
}
