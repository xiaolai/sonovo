import XCTest
@testable import Sonovo

final class NavigatorGroupExpansionTests: XCTestCase {
    func testGroupsStartExpandedAndToggleIndependently() {
        var expansion = NavigatorGroupExpansion<String>()
        XCTAssertTrue(expansion.isExpanded("script", forceExpanded: false))
        XCTAssertTrue(expansion.isExpanded("voice", forceExpanded: false))

        expansion.setExpanded(false, for: "script")
        XCTAssertFalse(expansion.isExpanded("script", forceExpanded: false))
        XCTAssertTrue(
            expansion.isExpanded("voice", forceExpanded: false),
            "collapsing one group must not collapse the others"
        )

        expansion.setExpanded(true, for: "script")
        XCTAssertTrue(expansion.isExpanded("script", forceExpanded: false))
    }

    /// A filter must never hide a match inside a group the user collapsed
    /// earlier; the FileTree navigator already behaves this way.
    func testAFilterForcesCollapsedGroupsOpen() {
        var expansion = NavigatorGroupExpansion<String>()
        expansion.setExpanded(false, for: "script")
        XCTAssertTrue(
            expansion.isExpanded("script", forceExpanded: true),
            "a match must not stay hidden behind a collapsed group"
        )
        XCTAssertFalse(
            expansion.isExpanded("script", forceExpanded: false),
            "clearing the filter restores the user's collapse"
        )
    }
}
