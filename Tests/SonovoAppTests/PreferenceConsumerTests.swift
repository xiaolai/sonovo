import XCTest
@testable import Sonovo

final class TerminalPreferencesTests: XCTestCase {
    func testParsesFontFamilyAndSize() {
        let parsed = TerminalPreferences.parsedFont(from: "SF Mono 12")
        XCTAssertEqual(parsed?.family, "SF Mono")
        XCTAssertEqual(parsed?.size, 12)

        let fractional = TerminalPreferences.parsedFont(from: "Menlo 13.5")
        XCTAssertEqual(fractional?.family, "Menlo")
        XCTAssertEqual(fractional?.size, 13.5)

        let familyOnly = TerminalPreferences.parsedFont(from: "Monaco")
        XCTAssertEqual(familyOnly?.family, "Monaco")
        XCTAssertEqual(familyOnly?.size, 12)

        XCTAssertNil(TerminalPreferences.parsedFont(from: "   "))
    }

    func testConfigTextUsesTheConfiguredFont() {
        let text = TerminalPreferences.configText()
        XCTAssertTrue(text.contains("font-family = SF Mono"))
        XCTAssertTrue(text.contains("font-size = 12.0"))
        XCTAssertFalse(text.contains("\n\n"))
    }
}

final class AudioOutputDevicesTests: XCTestCase {
    /// Enumerating devices must not crash and must return well-formed
    /// entries. The count depends on the machine, so it is not asserted.
    func testEnumeratesWellFormedDevices() {
        for device in AudioOutputDevices.all() {
            XCTAssertFalse(device.id.isEmpty)
            XCTAssertFalse(device.name.isEmpty)
        }
    }
}
