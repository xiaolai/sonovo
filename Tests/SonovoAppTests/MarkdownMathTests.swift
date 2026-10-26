import AppKit
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MarkdownMathTests: XCTestCase {
    private let renderer = MarkdownMathRenderer.shared

    override func setUp() async throws {
        renderer.removeAll()
    }

    private func layout(
        _ source: String,
        display: Bool = false,
        size: CGFloat = 16
    ) -> MarkdownMathLayout? {
        switch renderer.layout(
            source: source,
            display: display,
            fontSize: size,
            color: .black
        ) {
        case let .success(layout):
            return layout
        case .failure:
            return nil
        }
    }

    // MARK: - Typesetting

    func testInlineFormulaHasFiniteMetricsAndAnImage() throws {
        let layout = try XCTUnwrap(layout("x^2 + y^2 = z^2"))
        XCTAssertGreaterThan(layout.width, 0)
        XCTAssertGreaterThan(layout.ascent, 0)
        XCTAssertGreaterThanOrEqual(layout.descent, 0)
        XCTAssertEqual(layout.height, layout.ascent + layout.descent)
        XCTAssertEqual(layout.image.size.width, layout.width)
        XCTAssertEqual(layout.image.size.height, layout.height)
    }

    func testTexEdgeCasesTypeset() throws {
        for source in [
            "x_{i}^{2}",
            "\\sqrt{\\frac{a}{b}}",
            "\\left(\\frac{a}{b}\\right)",
            "\\text{if } x > 0",
            "\\sum_{i=1}^{n} i",
            "\\int_{0}^{1} x\\,dx",
            "\\begin{matrix} a & b \\\\ c & d \\end{matrix}",
            "\\alpha + \\beta = \\gamma"
        ] {
            XCTAssertNotNil(layout(source), "failed to typeset \(source)")
        }
    }

    func testDisplayStyleIsTallerForLimits() throws {
        let inline = try XCTUnwrap(layout("\\sum_{i=1}^{n} i", display: false))
        let display = try XCTUnwrap(layout("\\sum_{i=1}^{n} i", display: true))
        XCTAssertGreaterThan(display.height, inline.height)
    }

    func testInvalidTeXFails() {
        XCTAssertNil(layout("\\frac{a}{"))
        XCTAssertNil(layout("\\notAControlSequence{x}"))
        XCTAssertNil(layout(""))
        XCTAssertNil(layout("   "))
    }

    func testDeniedCommandsAreRejected() {
        for source in [
            "\\href{https://example.com}{x}",
            "\\url{https://example.com}",
            "\\includegraphics{/etc/passwd}",
            "\\input{/etc/passwd}",
            "\\def\\x{y}",
            "\\htmlClass{x}{y}"
        ] {
            guard case let .failure(error) = renderer.layout(
                source: source,
                display: false,
                fontSize: 16,
                color: .black
            ) else {
                XCTFail("renderer accepted \(source)")
                continue
            }
            XCTAssertEqual(error, .rejected)
        }
    }

    func testRenderedImageHasInk() throws {
        let layout = try XCTUnwrap(layout("x", size: 20))
        let data = try XCTUnwrap(
            renderer.pngData(
                for: layout,
                scale: AppTheme.MarkdownChrome.Math.exportScale
            )
        )
        let representation = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(
            representation.pixelsWide,
            Int((layout.width * AppTheme.MarkdownChrome.Math.exportScale).rounded(.up))
        )
        XCTAssertEqual(
            representation.pixelsHigh,
            Int((layout.height * AppTheme.MarkdownChrome.Math.exportScale).rounded(.up))
        )

        var inked = 0
        for y in 0..<representation.pixelsHigh {
            for x in 0..<representation.pixelsWide {
                if let alpha = representation.colorAt(x: x, y: y)?
                    .alphaComponent, alpha > 0.5 {
                    inked += 1
                }
            }
        }
        XCTAssertGreaterThan(inked, 20, "the rasterized formula is blank")
    }

    func testForeignColorIsHonored() throws {
        let black = try XCTUnwrap(
            renderer.layout(
                source: "x",
                display: false,
                fontSize: 20,
                color: .black
            ).value()
        )
        let red = try XCTUnwrap(
            renderer.layout(
                source: "x",
                display: false,
                fontSize: 20,
                color: .systemRed
            ).value()
        )
        XCTAssertNotEqual(
            renderer.pngData(for: black, scale: 2),
            renderer.pngData(for: red, scale: 2)
        )
        XCTAssertNotIdentical(black.image, red.image)
    }

    // MARK: - Cache

    func testCacheReturnsTheSameLayout() throws {
        let first = try XCTUnwrap(layout("a + b"))
        let second = try XCTUnwrap(layout("a + b"))
        XCTAssertIdentical(first.image, second.image)
    }

    func testDisplayAndInlineDoNotShareACacheEntry() throws {
        let inline = try XCTUnwrap(layout("\\sum_{i=1}^{n} i", display: false))
        let display = try XCTUnwrap(layout("\\sum_{i=1}^{n} i", display: true))
        XCTAssertNotIdentical(inline.image, display.image)
    }

    // MARK: - Performance

    func testHundredUniqueFormulasRenderWithinBudget() {
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for index in 0..<100 {
                _ = renderer.layout(
                    source: "x_{\(index)} + \\frac{a}{b}^{\(index)}",
                    display: false,
                    fontSize: 16,
                    color: .black
                )
            }
        }
        XCTAssertLessThan(elapsed, .seconds(10), "rendering took \(elapsed)")
    }

    func testCacheMakesRepeatedRendersCheap() throws {
        _ = try XCTUnwrap(layout("\\frac{a}{b}"))
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<1_000 {
                _ = renderer.layout(
                    source: "\\frac{a}{b}",
                    display: false,
                    fontSize: 16,
                    color: .black
                )
            }
        }
        XCTAssertLessThan(elapsed, .seconds(2), "cache lookup took \(elapsed)")
    }

    // MARK: - AST collection

    func testCollectorDeduplicatesInDocumentOrder() {
        let source = """
        One $a$ and $b$.

        $$
        a
        $$

        Again $a$ in a footnote[^n].

        [^n]: Note $c$.
        """
        let ast = MarkdownSyntaxAugmenter()
            .augment(MarkdownParser.parse(source))
        let nodes = MarkdownMathNodes.collect(from: ast)
        let sources = nodes.map(\.source)
        XCTAssertEqual(sources, ["a", "b", "\na\n", "c"])
    }
}

private extension Result where Failure == MarkdownMathError {
    func value() throws -> Success? {
        switch self {
        case let .success(value): return value
        case .failure: return nil
        }
    }
}
