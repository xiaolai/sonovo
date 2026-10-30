import AppKit
import CoreText
import XCTest
@testable import Sonovo

@MainActor
final class FontTests: XCTestCase {
    private func fallbackFamily(_ font: NSFont, _ text: String) -> String {
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            if let value = attributes[kCTFontAttributeName] {
                return CTFontCopyFamilyName(value as! CTFont) as String
            }
        }
        return ""
    }

    func testChineseCascadeKeepsLatinAndFallsBackToPingFang() throws {
        let charter = try XCTUnwrap(NSFont(name: "Charter", size: 17))
        let font = AppFonts.cascadedFont(
            charter,
            size: 17,
            chinese: "PingFang SC"
        )
        XCTAssertEqual(fallbackFamily(font, "Hello"), "Charter")
        XCTAssertEqual(fallbackFamily(font, "中文"), "PingFang SC")
    }

    func testSystemCodeFontCascadesChinese() throws {
        let font = AppFonts.cascadedFont(
            NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            size: 13,
            chinese: "PingFang SC"
        )
        XCTAssertEqual(fallbackFamily(font, "中文"), "PingFang SC")
    }

    func testChineseFaceValidationFallsBackToInstalledFace() throws {
        XCTAssertTrue(ChineseFace.installed.contains(.pingFangSC))
        XCTAssertEqual(
            ChineseFace.valid(fontName: "PingFang SC"),
            "PingFang SC"
        )
        XCTAssertNotNil(ChineseFace.valid(fontName: "No Such Face"))
        XCTAssertNil(ChineseFace.valid(fontName: ""))
    }

    func testNerdFontCatalogIsInstalledAndOrdered() {
        let families = NerdFonts.installedFamilies
        XCTAssertEqual(families, families.sorted { lhs, rhs in
            if lhs == NerdFonts.recommendedFamily { return true }
            if rhs == NerdFonts.recommendedFamily { return false }
            return lhs < rhs
        })
        for family in families {
            let lowered = family.lowercased()
            XCTAssertTrue(
                lowered.contains("nerd font")
                    || lowered.contains("meslolgs nf"),
                family
            )
        }
    }

    func testReadingFaceOverridesBodyAndHeadingsOnly() {
        let defaults = UserDefaults.standard
        let key = FontPreferences.readingFaceKey
        let previous = defaults.string(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(ReadingFace.charter.rawValue, forKey: key)

        let body = ThemeFont(
            families: [],
            design: .serif,
            role: .body
        )
        XCTAssertEqual(body.effectiveFamilies, ["Charter"])
        XCTAssertEqual(body.effectiveDesign, .serif)

        let heading = ThemeFont(
            families: [],
            design: .serif,
            role: .heading
        )
        XCTAssertEqual(heading.effectiveFamilies, ["Charter"])

        let chrome = ThemeFont(
            families: [],
            design: .sans,
            role: .ui
        )
        XCTAssertEqual(chrome.effectiveFamilies, [])
        XCTAssertEqual(chrome.effectiveDesign, .sans)

        let code = ThemeFont(
            families: [],
            design: .mono,
            role: .code
        )
        XCTAssertEqual(code.effectiveDesign, .mono)
    }

    func testReadingFacePreferenceValidatesTheStoredName() {
        let suite = "FontTests-reading-face"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(
            FontPreferences.readingFace(defaults: defaults),
            .theme
        )
        defaults.set(
            ReadingFace.charter.rawValue,
            forKey: FontPreferences.readingFaceKey
        )
        XCTAssertEqual(
            FontPreferences.readingFace(defaults: defaults),
            .charter
        )
        defaults.set(
            "no-such-face",
            forKey: FontPreferences.readingFaceKey
        )
        XCTAssertEqual(
            FontPreferences.readingFace(defaults: defaults),
            .theme
        )
    }

    func testCodeFontResolvesTheChosenFamily() throws {
        let font = AppFonts.codeFont(size: 13, family: "Charter")
        XCTAssertEqual(font.familyName, "Charter")
        XCTAssertEqual(fallbackFamily(font, "中文"), "PingFang SC")
    }
}
