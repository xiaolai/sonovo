import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class RenderedFindControllerTests: XCTestCase {
    private func match(_ id: Int) -> MarkdownRenderedMatch {
        MarkdownRenderedMatch(
            id: id,
            blockIndex: 0,
            location: id,
            length: 1,
            preview: "x"
        )
    }

    func testSteppingWraps() {
        let find = RenderedFindController()
        find.show()
        find.query = "x"
        find.setMatches([match(0), match(1), match(2)])
        XCTAssertEqual(find.countLabel, "1 of 3")
        find.step(1)
        XCTAssertEqual(find.currentIndex, 1)
        find.step(-1)
        find.step(-1)
        XCTAssertEqual(find.currentIndex, 2)
        XCTAssertEqual(find.countLabel, "3 of 3")
    }

    func testEmptyStates() {
        let find = RenderedFindController()
        XCTAssertEqual(find.countLabel, "")
        find.query = "missing"
        find.setMatches([])
        XCTAssertEqual(find.countLabel, "No matches")
        find.step(1)
        XCTAssertEqual(find.currentIndex, 0)
    }

    func testShowingAgainRequestsFocus() {
        let find = RenderedFindController()
        find.show()
        XCTAssertEqual(find.focusRequest, 1)
        find.show()
        XCTAssertEqual(find.focusRequest, 2)
        XCTAssertTrue(find.isVisible)
    }

    func testSetMatchesClampsTheIndex() {
        let find = RenderedFindController()
        find.query = "x"
        find.setMatches([match(0), match(1), match(2)])
        find.step(1)
        find.step(1)
        XCTAssertEqual(find.currentIndex, 2)
        find.setMatches([match(0)])
        XCTAssertEqual(find.currentIndex, 0)
    }
}
