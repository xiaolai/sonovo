import AppKit
import SonovoCore
import SwiftMath
import SwiftUI

/// A typeset formula: one vector image plus the metrics the text layout needs
/// to put the formula's baseline on the surrounding text's baseline.
struct MarkdownMathLayout {
    let image: NSImage
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat

    var height: CGFloat { ascent + descent }
}

enum MarkdownMathError: Error, Equatable {
    case empty
    case rejected
    case renderFailed(String)
}

/// Rasterized formula used by the HTML and PDF exporters.
///
/// Both theme variants are rendered ahead of time because the exported page
/// switches palette with `prefers-color-scheme`, and an image cannot inherit
/// `currentColor`.
struct MarkdownMathAsset: Sendable, Equatable {
    let lightPNG: Data
    let darkPNG: Data?
    let width: CGFloat
    let height: CGFloat
    let descent: CGFloat

    static func key(source: String, display: Bool) -> String {
        (display ? "d|" : "i|") + source
    }
}

/// One math node's identity, shared by the viewer's attributed text and the
/// export collector.
struct MarkdownMathPayload: Hashable, Sendable {
    let source: String
    let raw: String
    let display: Bool

    var key: String { MarkdownMathAsset.key(source: source, display: display) }
}

/// The attributed-string marker that reserves a formula's place in a run.
/// SwiftUI ignores the attribute itself; the viewer replaces those runs with
/// images.
enum MarkdownMathAttribute: AttributedStringKey {
    typealias Value = MarkdownMathPayload
    static let name = "sonovo.markdown.math"
}

// MARK: - Renderer

/// Typesets TeX with SwiftMath's native Core Graphics layout.
///
/// SwiftMath parses and lays out on the calling thread and only reads its own
/// font bundle; there is no JavaScript, network, or file access driven by the
/// formula. Layouts are cached by source, display mode, size, and ink.
@MainActor
final class MarkdownMathRenderer {
    static let shared = MarkdownMathRenderer()

    private var cache: [String: Result<MarkdownMathLayout, MarkdownMathError>] = [:]
    private var insertionOrder: [String] = []

    func layout(
        source: String,
        display: Bool,
        fontSize: CGFloat,
        color: NSColor
    ) -> Result<MarkdownMathLayout, MarkdownMathError> {
        let key = Self.cacheKey(
            source: source,
            display: display,
            fontSize: fontSize,
            color: color
        )
        if let cached = cache[key] {
            return cached
        }
        let result = typeset(
            source: source,
            display: display,
            fontSize: fontSize,
            color: color
        )
        store(key: key, result: result)
        return result
    }

    /// PNG pixels for a layout. The image is vector-backed, so rasterizing at
    /// a higher scale costs sharpness, not fidelity of the layout.
    func pngData(
        for layout: MarkdownMathLayout,
        scale: CGFloat
    ) -> Data? {
        let width = Int((layout.width * scale).rounded(.up))
        let height = Int((layout.height * scale).rounded(.up))
        guard width > 0, height > 0,
              width <= 16_384, height <= 16_384,
              let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else {
            return nil
        }
        representation.size = NSSize(
            width: layout.width,
            height: layout.height
        )
        guard let context = NSGraphicsContext(bitmapImageRep: representation)
        else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.setShouldAntialias(true)
        context.cgContext.interpolationQuality = .high
        layout.image.draw(
            in: NSRect(x: 0, y: 0, width: layout.width, height: layout.height)
        )
        NSGraphicsContext.restoreGraphicsState()
        return representation.representation(using: .png, properties: [:])
    }

    func removeAll() {
        cache.removeAll(keepingCapacity: false)
        insertionOrder.removeAll(keepingCapacity: false)
    }

    // MARK: Typesetting

    private func typeset(
        source: String,
        display: Bool,
        fontSize: CGFloat,
        color: NSColor
    ) -> Result<MarkdownMathLayout, MarkdownMathError> {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .failure(.empty)
        }
        // The scanner already applied this policy; repeat it here so no
        // caller can hand the typesetter a rejected formula.
        guard MarkdownMathPolicy.accepts(source) else {
            return .failure(.rejected)
        }

        let label = MTMathUILabel()
        label.latex = source
        label.fontSize = fontSize
        label.textColor = color
        label.labelMode = display ? .display : .text
        label.displayErrorInline = false

        if let error = label.error {
            return .failure(.renderFailed(error.localizedDescription))
        }

        let fitting = label.fittingSize
        guard fitting.width.isFinite, fitting.height.isFinite,
              fitting.width > 0, fitting.height > 0 else {
            return .failure(.renderFailed("empty layout"))
        }
        label.frame = CGRect(origin: .zero, size: fitting)
        label.layout()

        guard let list = label.displayList else {
            return .failure(.renderFailed("no display list"))
        }
        let width = list.width
        let ascent = list.ascent
        let descent = list.descent
        guard width.isFinite, ascent.isFinite, descent.isFinite,
              width > 0, ascent >= 0, descent >= 0 else {
            return .failure(.renderFailed("invalid metrics"))
        }

        let size = NSSize(width: width, height: ascent + descent)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }
            context.saveGState()
            list.draw(context)
            context.restoreGState()
            return true
        }
        return .success(
            MarkdownMathLayout(
                image: image,
                width: width,
                ascent: ascent,
                descent: descent
            )
        )
    }

    // MARK: Cache

    private func store(
        key: String,
        result: Result<MarkdownMathLayout, MarkdownMathError>
    ) {
        if cache[key] == nil {
            insertionOrder.append(key)
        }
        cache[key] = result
        let limit = MarkdownLimits.maxMathRenderCacheEntries
        if insertionOrder.count > limit {
            let removeCount = max(1, limit / 4)
            for stale in insertionOrder.prefix(removeCount) {
                cache.removeValue(forKey: stale)
            }
            insertionOrder.removeFirst(removeCount)
        }
    }

    private static func cacheKey(
        source: String,
        display: Bool,
        fontSize: CGFloat,
        color: NSColor
    ) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let components = [
            rgb.redComponent,
            rgb.greenComponent,
            rgb.blueComponent,
            rgb.alphaComponent
        ].map { String(format: "%.4f", $0) }.joined(separator: ",")
        return "\(display ? "d" : "i")|\(fontSize)|\(components)|\(source)"
    }
}

// MARK: - AST collection

enum MarkdownMathNodes {
    /// Every distinct formula in the document, in document order.
    static func collect(from ast: SonovoAST) -> [MarkdownMathPayload] {
        var seen = Set<MarkdownMathPayload>()
        var result: [MarkdownMathPayload] = []

        func add(_ inline: Inline) {
            switch inline {
            case let .math(source, raw, display, _):
                let payload = MarkdownMathPayload(
                    source: source,
                    raw: raw,
                    display: display
                )
                if seen.insert(payload).inserted {
                    result.append(payload)
                }
            case let .emphasis(children, _),
                 let .strong(children, _),
                 let .strikethrough(children, _):
                children.forEach(add)
            case let .link(_, _, children, _):
                children.forEach(add)
            case let .image(_, _, description, _):
                description.forEach(add)
            default:
                break
            }
        }

        func add(_ blocks: [Block]) {
            for block in blocks {
                switch block {
                case let .paragraph(inlines, _),
                     let .heading(_, inlines, _):
                    inlines.forEach(add)
                case let .blockQuote(children, _):
                    add(children)
                case let .list(list, _):
                    for item in list.items { add(item.blocks) }
                case let .table(table, _):
                    for cell in table.header { cell.inlines.forEach(add) }
                    for row in table.rows {
                        for cell in row { cell.inlines.forEach(add) }
                    }
                case let .definitionList(list, _):
                    for item in list.items {
                        for term in item.terms { term.inlines.forEach(add) }
                        for definition in item.definitions {
                            definition.inlines.forEach(add)
                        }
                    }
                case let .details(details, _):
                    details.summary.forEach(add)
                    add(details.blocks)
                case let .footnotes(section, _):
                    for entry in section.entries { entry.inlines.forEach(add) }
                default:
                    break
                }
            }
        }

        add(ast.blocks)
        return result
    }
}

// MARK: - Export assets

@MainActor
enum MarkdownMathAssets {
    /// Renders every formula once for both palettes. A formula the renderer
    /// rejects is simply absent; the exporter falls back to literal source.
    static func build(
        from ast: SonovoAST,
        theme: MarkdownTheme,
        byteBudget: Int = MarkdownLimits.maxMathExportBytes
    ) -> [String: MarkdownMathAsset] {
        let nodes = MarkdownMathNodes.collect(from: ast)
            .prefix(MarkdownLimits.maxRenderedMathFormulas)
        guard !nodes.isEmpty else { return [:] }

        let renderer = MarkdownMathRenderer.shared
        let light = theme.palette(for: .light)
        let dark = theme.palette(for: .dark)
        var assets: [String: MarkdownMathAsset] = [:]
        assets.reserveCapacity(nodes.count)
        var totalBytes = 0

        for node in nodes {
            let fontSize = theme.bodySize
            let lightResult = renderer.layout(
                source: node.source,
                display: node.display,
                fontSize: fontSize,
                color: light.ink.nsColor
            )
            guard case let .success(lightLayout) = lightResult,
                  let lightPNG = renderer.pngData(
                    for: lightLayout,
                    scale: AppTheme.MarkdownChrome.Math.exportScale
                  ) else {
                continue
            }
            var darkPNG: Data?
            if light.ink == dark.ink {
                darkPNG = lightPNG
            } else if case let .success(darkLayout) = renderer.layout(
                source: node.source,
                display: node.display,
                fontSize: fontSize,
                color: dark.ink.nsColor
            ) {
                darkPNG = renderer.pngData(
                    for: darkLayout,
                    scale: AppTheme.MarkdownChrome.Math.exportScale
                )
            }
            let extraBytes = lightPNG.count + (darkPNG?.count ?? 0)
            if totalBytes + extraBytes > byteBudget {
                // Stop spending export size on formulas; the rest stay
                // literal source through the missing-asset fallback.
                break
            }
            assets[node.key] = MarkdownMathAsset(
                lightPNG: lightPNG,
                darkPNG: darkPNG,
                width: lightLayout.width,
                height: lightLayout.height,
                descent: lightLayout.descent
            )
            totalBytes += extraBytes
        }
        return assets
    }
}

extension ThemeColor {
    var nsColor: NSColor {
        NSColor(
            srgbRed: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }
}
