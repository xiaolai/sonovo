import XCTest
@testable import Sonovo

/// Proves the executable module is importable from a test target, which the
/// native AppKit/SwiftUI gates depend on.
final class AppSmokeTests: XCTestCase {
    func testExecutableModuleIsImportable() {
        XCTAssertEqual(EditorMode.allCases.count, 3)
        XCTAssertEqual(NavigatorMode.allCases.count, 2)
    }

    @MainActor
    func testMarkdownWordCountCountsCJKPunctuationSeparately() {
        let state = AppState()
        XCTAssertEqual(state.markdownWordCount("hello world"), 2)
        XCTAssertEqual(state.markdownWordCount("one, two."), 2)
        XCTAssertEqual(state.markdownWordCount("多 空 白"), 3)
        XCTAssertEqual(state.markdownWordCount("混合 text 统计"), 5)
    }
}
