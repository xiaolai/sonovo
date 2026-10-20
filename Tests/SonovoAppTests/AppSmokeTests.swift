import XCTest
@testable import Sonovo

/// Proves the executable module is importable from a test target, which the
/// native AppKit/SwiftUI gates depend on.
final class AppSmokeTests: XCTestCase {
    func testExecutableModuleIsImportable() {
        XCTAssertEqual(EditorMode.allCases.count, 3)
        XCTAssertEqual(NavigatorMode.allCases.count, 2)
    }
}
