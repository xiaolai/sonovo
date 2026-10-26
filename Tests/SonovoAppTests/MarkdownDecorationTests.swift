import AppKit
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MarkdownDecorationTests: XCTestCase {
    private func makeController(
        source: String
    ) -> (MarkdownDocument, MarkdownEditorController) {
        let document = MarkdownDocument(untitledWith: MarkdownFileStore())
        try? document.replaceSource(source)
        let cache = MarkdownEditorCache()
        let controller = cache.entry(
            for: document,
            parseCoordinator: MarkdownParseCoordinator(
                service: MarkdownParseService()
            ),
            parseDebounce: 0
        ).controller
        return (document, controller)
    }

    private func output(
        for document: MarkdownDocument
    ) -> MarkdownParseOutput {
        let parsed = MarkdownParser.parseCanonical(document.source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        return MarkdownParseOutput(
            documentID: document.id,
            revision: document.revision,
            parsed: parsed,
            ast: ast,
            headings: HeadingIndex(ast: ast)
        )
    }

    func testLayersCoexistAndTogglingOneRestoresTheOthers() throws {
        let source = "# Title\n\nBody text here.\n"
        let (document, controller) = makeController(source: source)
        let parsed = output(for: document)
        controller.applyHighlight(parsed)

        let storage = try XCTUnwrap(controller.textView.textStorage)
        let bodyRange = (source as NSString).range(of: "Body text")
        let syntaxColor = storage.attribute(
            .foregroundColor,
            at: bodyRange.location,
            effectiveRange: nil
        ) as? NSColor
        let syntaxFont = storage.attribute(
            .font,
            at: bodyRange.location,
            effectiveRange: nil
        ) as? NSFont
        XCTAssertNotNil(syntaxColor)
        XCTAssertNotNil(syntaxFont)

        let lintColor = NSColor.systemRed
        let cellColor = NSColor.systemYellow
        let focusColor = NSColor.systemGray
        let decorations = MarkdownDecorationSet(
            focus: [
                MarkdownDecoration(
                    layer: .focus,
                    range: bodyRange,
                    attributes: [.foregroundColor: focusColor]
                )
            ],
            cell: [
                MarkdownDecoration(
                    layer: .cell,
                    range: bodyRange,
                    attributes: [.backgroundColor: cellColor]
                )
            ],
            lint: [
                MarkdownDecoration(
                    layer: .lint,
                    range: bodyRange,
                    attributes: [
                        .foregroundColor: lintColor,
                        .underlineStyle:
                            NSUnderlineStyle.single.rawValue
                    ]
                )
            ]
        )
        controller.applyHighlight(parsed, decorations: decorations)

        // Lint wins the foreground; the cell owns the background; the font
        // still belongs to syntax.
        XCTAssertEqual(
            storage.attribute(
                .foregroundColor,
                at: bodyRange.location,
                effectiveRange: nil
            ) as? NSColor,
            lintColor
        )
        XCTAssertEqual(
            storage.attribute(
                .backgroundColor,
                at: bodyRange.location,
                effectiveRange: nil
            ) as? NSColor,
            cellColor
        )
        XCTAssertEqual(
            storage.attribute(
                .underlineStyle,
                at: bodyRange.location,
                effectiveRange: nil
            ) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        XCTAssertEqual(
            storage.attribute(
                .font,
                at: bodyRange.location,
                effectiveRange: nil
            ) as? NSFont,
            syntaxFont
        )

        // Turning lint off restores the syntax color and removes only the
        // lint keys; the cell background survives.
        controller.applyHighlight(
            parsed,
            decorations: MarkdownDecorationSet(cell: decorations.cell)
        )
        XCTAssertEqual(
            storage.attribute(
                .foregroundColor,
                at: bodyRange.location,
                effectiveRange: nil
            ) as? NSColor,
            syntaxColor
        )
        XCTAssertEqual(
            storage.attribute(
                .backgroundColor,
                at: bodyRange.location,
                effectiveRange: nil
            ) as? NSColor,
            cellColor
        )
        XCTAssertNil(
            storage.attribute(
                .underlineStyle,
                at: bodyRange.location,
                effectiveRange: nil
            )
        )

        controller.applyHighlight(parsed)
        XCTAssertEqual(
            storage.attribute(
                .foregroundColor,
                at: bodyRange.location,
                effectiveRange: nil
            ) as? NSColor,
            syntaxColor
        )
        XCTAssertNil(
            storage.attribute(
                .backgroundColor,
                at: bodyRange.location,
                effectiveRange: nil
            ) as? NSColor
        )
        XCTAssertEqual(controller.textView.string, source)
        XCTAssertNotNil(controller.textView.textLayoutManager)
    }

    func testLintMarksApplyAndNavigate() async throws {
        let source = "#NoSpace\n\n[a][missing]\n"
        let (document, controller) = makeController(source: source)
        controller.applyHighlight(output(for: document))
        let storage = try XCTUnwrap(controller.textView.textStorage)
        controller.setLintDiagnostics([
            MarkdownDiagnostic(
                ruleID: "E04",
                severity: .error,
                range: 0..<8,
                message: "heading"
            ),
            MarkdownDiagnostic(
                ruleID: "E01",
                severity: .error,
                range: 10..<22,
                message: "reference"
            )
        ])
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(
            storage.attribute(
                .underlineStyle,
                at: 0,
                effectiveRange: nil
            ) as? Int,
            NSUnderlineStyle.single.rawValue
        )

        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.goToDiagnostic(backwards: false)
        XCTAssertEqual(controller.textView.selectedRange().location, 10)
        controller.goToDiagnostic(backwards: true)
        XCTAssertEqual(controller.textView.selectedRange().location, 0)
    }

    func testADecorationCannotWriteAKeyItsLayerDoesNotOwn() throws {
        let source = "Body\n"
        let (document, controller) = makeController(source: source)
        let parsed = output(for: document)
        controller.applyHighlight(parsed)
        let storage = try XCTUnwrap(controller.textView.textStorage)
        let font = NSFont.systemFont(ofSize: 42)
        controller.applyHighlight(
            parsed,
            decorations: MarkdownDecorationSet(
                lint: [
                    MarkdownDecoration(
                        layer: .lint,
                        range: NSRange(location: 0, length: 4),
                        attributes: [.font: font]
                    )
                ]
            )
        )
        XCTAssertNotEqual(
            storage.attribute(
                .font,
                at: 0,
                effectiveRange: nil
            ) as? NSFont,
            font
        )
    }
}
