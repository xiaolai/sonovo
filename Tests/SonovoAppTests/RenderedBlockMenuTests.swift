import XCTest
@testable import Sonovo
import SonovoCore

final class RenderedBlockMenuTests: XCTestCase {
    private func sourceRange(_ offsets: Range<Int>) -> SourceRange {
        SourceRange(
            start: SourcePosition(
                line: 1,
                column: offsets.lowerBound,
                offset: offsets.lowerBound
            ),
            end: SourcePosition(
                line: 1,
                column: offsets.upperBound,
                offset: offsets.upperBound
            )
        )
    }

    private func details(isOpen: Bool) -> Block {
        .details(
            DetailsBlock(
                summary: [.text("S", range: nil)],
                blocks: [],
                isOpen: isOpen,
                range: sourceRange(0..<10)
            ),
            range: sourceRange(0..<10)
        )
    }

    func testDetailsMenuOffersTheOppositeDefault() {
        XCTAssertEqual(
            RenderedBlockMenu.actions(
                for: details(isOpen: true),
                canEditInSource: true,
                canSetDetailsOpen: true
            ),
            [.editInSource, .setDetailsOpen(false)]
        )
        XCTAssertEqual(
            RenderedBlockMenu.actions(
                for: details(isOpen: false),
                canEditInSource: true,
                canSetDetailsOpen: true
            ),
            [.editInSource, .setDetailsOpen(true)]
        )
    }

    func testDetailsMenuNeedsItsHandler() {
        XCTAssertEqual(
            RenderedBlockMenu.actions(
                for: details(isOpen: false),
                canEditInSource: false,
                canSetDetailsOpen: false
            ),
            []
        )
    }

    func testNonDetailsBlockNeverOffersTheOpenAction() {
        XCTAssertEqual(
            RenderedBlockMenu.actions(
                for: .paragraph(
                    inlines: [.text("x", range: nil)],
                    range: sourceRange(0..<1)
                ),
                canEditInSource: true,
                canSetDetailsOpen: true
            ),
            [.editInSource]
        )
    }

    func testActionTitles() {
        XCTAssertEqual(RenderedBlockAction.editInSource.title, "Edit in Source")
        XCTAssertEqual(RenderedBlockAction.editBlock.title, "Edit Block")
        XCTAssertEqual(RenderedBlockAction.sourcePeek.title, "Source Peek")
        XCTAssertEqual(
            RenderedBlockAction.setDetailsOpen(true).title,
            "Open by Default"
        )
        XCTAssertEqual(
            RenderedBlockAction.setDetailsOpen(false).title,
            "Closed by Default"
        )
    }

    func testSourceProjectionActionsNeedARangeAndAHandler() {
        let paragraph = Block.paragraph(
            inlines: [.text("x", range: nil)],
            range: sourceRange(0..<1)
        )
        XCTAssertEqual(
            RenderedBlockMenu.actions(
                for: paragraph,
                canEditInSource: true,
                canSetDetailsOpen: false,
                canEditBlock: true
            ),
            [.editInSource, .editBlock, .sourcePeek]
        )
        XCTAssertEqual(
            RenderedBlockMenu.actions(
                for: .paragraph(inlines: [], range: nil),
                canEditInSource: false,
                canSetDetailsOpen: false,
                canEditBlock: true
            ),
            []
        )
        XCTAssertEqual(
            RenderedBlockMenu.actions(
                for: paragraph,
                canEditInSource: false,
                canSetDetailsOpen: false,
                canEditBlock: false
            ),
            []
        )
    }

    func testSourceProjectionRouting() {
        var edited: SourceRange?
        RenderedBlockMenu.perform(
            .editBlock,
            range: sourceRange(2..<6),
            editInSource: nil,
            setDetailsOpen: nil,
            editBlock: { edited = $0 }
        )
        XCTAssertEqual(edited, sourceRange(2..<6))

        var peeked: SourceRange?
        RenderedBlockMenu.perform(
            .sourcePeek,
            range: sourceRange(6..<9),
            editInSource: nil,
            setDetailsOpen: nil,
            sourcePeek: { peeked = $0 }
        )
        XCTAssertEqual(peeked, sourceRange(6..<9))
    }

    func testDoubleClickEditsOnlyWhenTheRouteExists() {
        XCTAssertEqual(
            RenderedBlockMenu.doubleClickAction(
                for: details(isOpen: true),
                canEditInSource: true
            ),
            .editInSource
        )
        XCTAssertNil(
            RenderedBlockMenu.doubleClickAction(
                for: details(isOpen: true),
                canEditInSource: false
            )
        )
        XCTAssertNil(
            RenderedBlockMenu.doubleClickAction(
                for: .paragraph(inlines: [], range: nil),
                canEditInSource: true
            )
        )
    }

    func testRoutingReachesTheDetailsHandler() {
        var received: (SourceRange, Bool)?
        RenderedBlockMenu.perform(
            .setDetailsOpen(true),
            range: sourceRange(4..<20),
            editInSource: nil,
            setDetailsOpen: { received = ($0, $1) }
        )
        XCTAssertEqual(received?.0, sourceRange(4..<20))
        XCTAssertEqual(received?.1, true)

        var edited: SourceRange?
        RenderedBlockMenu.perform(
            .editInSource,
            range: sourceRange(4..<20),
            editInSource: { edited = $0 },
            setDetailsOpen: nil
        )
        XCTAssertEqual(edited, sourceRange(4..<20))
    }
}
