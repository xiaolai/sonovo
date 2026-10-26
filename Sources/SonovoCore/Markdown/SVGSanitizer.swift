import Foundation

/// A sanitized SVG document plus the intrinsic size its root declares.
public struct SanitizedSVG: Equatable, Sendable {
    public let markup: String
    public let width: Double?
    public let height: Double?

    public init(markup: String, width: Double?, height: Double?) {
        self.markup = markup
        self.width = width
        self.height = height
    }
}

/// Extracts one SVG document from a byte string that may carry an XML
/// declaration, a doctype, comments, or surrounding whitespace.
///
/// Graphviz emits a prolog; authored SVG fences may too. `SVGSanitizer`
/// deliberately refuses doctypes, so the prolog is dropped before parsing and
/// only the element itself is handed to it.
public enum SVGSource {
    public static func document(from raw: String) -> String? {
        let text = raw
        var index = text.startIndex
        while index < text.endIndex {
            guard let open = text[index...].firstIndex(of: "<") else {
                return nil
            }
            let rest = text[open...]
            // A root opener inside a comment, processing instruction,
            // CDATA section, or doctype is not the document element:
            // `<!-- <svg example> --><svg>…</svg>` must not extract the
            // example. Skip these constructs whole.
            if rest.hasPrefix("<!--") {
                guard let close = text.range(
                    of: "-->",
                    range: text.index(open, offsetBy: 4)..<text.endIndex
                ) else { return nil }
                index = close.upperBound
                continue
            }
            if rest.hasPrefix("<?") {
                guard let close = text.range(
                    of: "?>",
                    range: text.index(open, offsetBy: 2)..<text.endIndex
                ) else { return nil }
                index = close.upperBound
                continue
            }
            if rest.hasPrefix("<![CDATA[") {
                guard let close = text.range(
                    of: "]]>",
                    range: text.index(open, offsetBy: 9)..<text.endIndex
                ) else { return nil }
                index = close.upperBound
                continue
            }
            let lowered = rest.prefix(9).lowercased()
            if lowered.hasPrefix("<!doctype") {
                guard let close = text.range(
                    of: ">",
                    range: text.index(after: open)..<text.endIndex
                ) else { return nil }
                index = close.upperBound
                continue
            }
            guard svgTagStart(rest) else {
                index = text.index(after: open)
                continue
            }
            let remainder = text[open...]
            // XML permits whitespace before the closing `>`: `</svg >` is
            // valid and must not reject the whole fence.
            var searchEnd = remainder.endIndex
            while let end = remainder.range(
                of: "</svg",
                options: [.caseInsensitive, .backwards],
                range: remainder.startIndex..<searchEnd
            ) {
                var probe = end.upperBound
                while probe < remainder.endIndex,
                      remainder[probe].isWhitespace {
                    probe = remainder.index(after: probe)
                }
                if probe < remainder.endIndex, remainder[probe] == ">" {
                    return String(
                        text[open..<remainder.index(after: probe)]
                    )
                }
                searchEnd = end.lowerBound
            }
            return nil
        }
        return nil
    }

    /// Whether `rest` starts with an `<svg>` open tag. `<svgo>` and `<svgfoo>`
    /// are different elements.
    private static func svgTagStart(_ rest: Substring) -> Bool {
        let lowered = rest.prefix(5).lowercased()
        guard lowered.hasPrefix("<svg") else { return false }
        let after = rest.index(rest.startIndex, offsetBy: 4)
        guard after < rest.endIndex else { return true }
        let next = rest[after]
        return next == ">" || next == "/" || next.isWhitespace
    }
}

/// A whitelist sanitizer for SVG produced by a diagram engine or authored in
/// an `svg` fence.
///
/// Mermaid output is treated as untrusted: the diagram source is authored
/// content and Mermaid's own sanitizer has had escapes before. The sanitizer
/// parses with `XMLParser` (external entities disabled, doctypes refused) and
/// re-serializes only known SVG elements and attributes. Anything it does not
/// understand is dropped with its subtree. Script, `foreignObject`, event
/// handlers, remote references, and non-local `url(…)` values cannot survive
/// the round trip.
public enum SVGSanitizer {
    /// Sanitizes one SVG string, or returns `nil` when it is unparseable,
    /// empty, not rooted in `<svg>`, larger than `maximumBytes`, or still
    /// parsing when `timeLimit` expires.
    public static func sanitize(
        _ svg: String,
        maximumBytes: Int = MarkdownLimits.maxMermaidSVGBytes,
        timeLimit: Duration = .seconds(
            MarkdownLimits.svgSanitizeTimeoutSeconds
        )
    ) -> SanitizedSVG? {
        guard maximumBytes > 0, !svg.isEmpty else { return nil }
        var source = svg
        // XML defines only five named entities; HTML diagrams can carry
        // `&nbsp;` and friends, which a strict parser rejects.
        for (entity, replacement) in namedEntities {
            source = source.replacingOccurrences(of: entity, with: replacement)
        }
        guard let data = source.data(using: .utf8),
              data.count <= max(maximumBytes * 2, 1_048_576) else {
            return nil
        }
        let lowered = source.lowercased()
        for refused in ["<!doctype", "<!entity", "<?xml-stylesheet"] {
            guard !lowered.contains(refused) else { return nil }
        }

        let delegate = SanitizerDelegate(
            maximumBytes: maximumBytes,
            timeLimit: timeLimit,
            scopeID: "sonovo-svg-" + String(
                ReviewDigest.hex(Data(source.utf8)).prefix(12)
            )
        )
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        delegate.parser = parser
        guard parser.parse(), !delegate.failed, let result = delegate.result
        else {
            return nil
        }
        return result
    }

    private static let namedEntities: [(String, String)] = [
        ("&nbsp;", "\u{00A0}"),
        ("&hellip;", "\u{2026}"),
        ("&mdash;", "\u{2014}"),
        ("&ndash;", "\u{2013}"),
        ("&middot;", "\u{00B7}"),
        ("&times;", "\u{00D7}"),
        ("&rarr;", "\u{2192}"),
        ("&larr;", "\u{2190}"),
        ("&copy;", "\u{00A9}")
    ]
}

// MARK: - Elements and attributes

private enum SVGWhitelist {
    static let elements: [String: String] = [
        "svg": "svg",
        "g": "g",
        "defs": "defs",
        "style": "style",
        "title": "title",
        "desc": "desc",
        "path": "path",
        "rect": "rect",
        "circle": "circle",
        "ellipse": "ellipse",
        "line": "line",
        "polyline": "polyline",
        "polygon": "polygon",
        "text": "text",
        "tspan": "tspan",
        "textpath": "textPath",
        "marker": "marker",
        "mask": "mask",
        "clippath": "clipPath",
        "pattern": "pattern",
        "lineargradient": "linearGradient",
        "radialgradient": "radialGradient",
        "stop": "stop",
        "filter": "filter",
        "feblend": "feBlend",
        "fecolormatrix": "feColorMatrix",
        "fecomposite": "feComposite",
        "fedropshadow": "feDropShadow",
        "fegaussianblur": "feGaussianBlur",
        "femerge": "feMerge",
        "feMergeNode".lowercased(): "feMergeNode",
        "feoffset": "feOffset",
        "fespecularlighting": "feSpecularLighting",
        "use": "use",
        "symbol": "symbol"
    ]

    static let attributes: [String: String] = [
        "id": "id",
        "class": "class",
        "style": "style",
        "transform": "transform",
        "d": "d",
        "x": "x",
        "y": "y",
        "x1": "x1",
        "y1": "y1",
        "x2": "x2",
        "y2": "y2",
        "dx": "dx",
        "dy": "dy",
        "cx": "cx",
        "cy": "cy",
        "r": "r",
        "rx": "rx",
        "ry": "ry",
        "width": "width",
        "height": "height",
        "viewbox": "viewBox",
        "preserveaspectratio": "preserveAspectRatio",
        "points": "points",
        "fill": "fill",
        "fill-opacity": "fill-opacity",
        "stroke": "stroke",
        "stroke-width": "stroke-width",
        "stroke-dasharray": "stroke-dasharray",
        "stroke-dashoffset": "stroke-dashoffset",
        "stroke-linecap": "stroke-linecap",
        "stroke-linejoin": "stroke-linejoin",
        "stroke-opacity": "stroke-opacity",
        "opacity": "opacity",
        "marker-start": "marker-start",
        "marker-mid": "marker-mid",
        "marker-end": "marker-end",
        "markerwidth": "markerWidth",
        "markerheight": "markerHeight",
        "markerunits": "markerUnits",
        "orient": "orient",
        "refx": "refX",
        "refy": "refY",
        "stddeviation": "stdDeviation",
        "flood-color": "flood-color",
        "flood-opacity": "flood-opacity",
        "offset": "offset",
        "stop-color": "stop-color",
        "stop-opacity": "stop-opacity",
        "gradientunits": "gradientUnits",
        "gradienttransform": "gradientTransform",
        "patternunits": "patternUnits",
        "patterntransform": "patternTransform",
        "clip-path": "clip-path",
        "mask": "mask",
        "filter": "filter",
        "color": "color",
        "display": "display",
        "visibility": "visibility",
        "text-anchor": "text-anchor",
        "dominant-baseline": "dominant-baseline",
        "alignment-baseline": "alignment-baseline",
        "font-family": "font-family",
        "font-size": "font-size",
        "font-weight": "font-weight",
        "font-style": "font-style",
        "letter-spacing": "letter-spacing",
        "word-spacing": "word-spacing",
        "textlength": "textLength",
        "lengthadjust": "lengthAdjust",
        "role": "role",
        "aria-label": "aria-label",
        "aria-roledescription": "aria-roledescription",
        "aria-labelledby": "aria-labelledby",
        "aria-describedby": "aria-describedby",
        "aria-hidden": "aria-hidden",
        "xmlns": "xmlns",
        "xmlns:xlink": "xmlns:xlink",
        "href": "href",
        "xlink:href": "xlink:href"
    ]

    /// CSS properties Mermaid uses for author overrides. Unknown properties
    /// are dropped rather than passed through.
    static let cssProperties: Set<String> = [
        "fill",
        "fill-opacity",
        "stroke",
        "stroke-width",
        "stroke-dasharray",
        "stroke-dashoffset",
        "stroke-linecap",
        "stroke-linejoin",
        "stroke-opacity",
        "opacity",
        "color",
        "font-family",
        "font-size",
        "font-weight",
        "font-style",
        "letter-spacing",
        "word-spacing",
        "text-anchor",
        "dominant-baseline",
        "display",
        "visibility",
        "max-width",
        "width",
        "height",
        "background-color",
        "border",
        "border-radius",
        "border-color",
        "border-width",
        "border-style",
        "padding",
        "margin",
        "line-height",
        "white-space",
        "text-align",
        "filter"
    ]
}

// MARK: - Parser delegate

private final class SanitizerDelegate: NSObject, XMLParserDelegate {
    let maximumBytes: Int
    weak var parser: XMLParser?

    private(set) var failed = false
    private var output = ""
    private var outputBytes = 0
    private var stack: [String] = []
    private var skipDepth = 0
    private var styleBuffer = ""
    private var styleBytes = 0
    private var rootSeen = false
    private var rootID: String?
    private var width: Double?
    private var height: Double?
    private let deadline: ContinuousClock.Instant
    /// The id this sanitizer gives the root when the authored SVG has none.
    /// Embedded stylesheets are scoped to it so a rule cannot reach the host
    /// page.
    private let scopeID: String

    init(maximumBytes: Int, timeLimit: Duration, scopeID: String) {
        self.maximumBytes = maximumBytes
        self.deadline = ContinuousClock.now + timeLimit
        self.scopeID = scopeID
    }

    /// Stops parsing once the caller's time budget is spent. Checking at
    /// parser events bounds the work between checks; the byte caps bound
    /// each individual event.
    private func exhausted(_ parser: XMLParser) -> Bool {
        guard ContinuousClock.now < deadline else {
            failed = true
            parser.abortParsing()
            return true
        }
        return false
    }

    var result: SanitizedSVG? {
        guard !failed, rootSeen, !output.isEmpty else { return nil }
        return SanitizedSVG(markup: output, width: width, height: height)
    }

    // MARK: Elements

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard !failed else { return }
        guard !exhausted(parser) else { return }
        if skipDepth > 0 {
            skipDepth += 1
            return
        }
        let lowered = elementName.lowercased()
        guard let canonical = SVGWhitelist.elements[lowered] else {
            skipDepth = 1
            return
        }
        if stack.isEmpty {
            guard canonical == "svg", !rootSeen else {
                fail()
                return
            }
            rootSeen = true
        }

        var opening = "<\(canonical)"
        let isRoot = stack.isEmpty
        var explicitWidth: Double?
        var explicitHeight: Double?
        var viewWidth: Double?
        var viewHeight: Double?
        for (key, rawValue) in attributeDict.sorted(by: { $0.key < $1.key }) {
            guard let attribute = SVGWhitelist.attributes[key.lowercased()]
            else { continue }
            guard let value = SanitizeValue.attribute(
                named: attribute,
                raw: rawValue
            ) else { continue }
            if isRoot, attribute == "id" {
                rootID = value
            }
            if isRoot, attribute == "viewBox" {
                let box = SanitizeValue.viewBox(value)
                viewWidth = box?.width
                viewHeight = box?.height
            }
            if isRoot, attribute == "width",
               let parsed = SanitizeValue.length(value) {
                explicitWidth = parsed
            }
            if isRoot, attribute == "height",
               let parsed = SanitizeValue.length(value) {
                explicitHeight = parsed
            }
            opening += " \(attribute)=\"\(escapeAttribute(value))\""
        }
        if isRoot {
            // An explicit absolute size wins; the viewBox is the fallback.
            width = explicitWidth ?? viewWidth
            height = explicitHeight ?? viewHeight
            if rootID == nil {
                // Stylesheets are scoped to this id; without one the sheet
                // could only be dropped.
                rootID = scopeID
                opening += " id=\"\(escapeAttribute(scopeID))\""
            }
        }
        opening += ">"
        append(opening)
        stack.append(canonical)
        if canonical == "style" {
            styleBuffer = ""
            styleBytes = 0
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard !failed else { return }
        if skipDepth > 0 {
            skipDepth -= 1
            return
        }
        guard let canonical = stack.popLast() else {
            fail()
            return
        }
        if canonical == "style" {
            if let css = SanitizeValue.stylesheet(
                styleBuffer,
                rootID: rootID
            ) {
                append(escapeText(css))
            }
            styleBuffer = ""
        }
        append("</\(canonical)>")
    }

    // MARK: Content

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !failed, skipDepth == 0 else { return }
        guard !exhausted(parser) else { return }
        if stack.last == "style" {
            styleBytes += string.utf8.count
            guard styleBytes <= 512 * 1024 else {
                fail()
                return
            }
            styleBuffer += string
        } else {
            append(escapeText(string))
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !failed, skipDepth == 0 else { return }
        guard !exhausted(parser) else { return }
        let text = String(decoding: CDATABlock, as: UTF8.self)
        if stack.last == "style" {
            styleBytes += text.utf8.count
            guard styleBytes <= 512 * 1024 else {
                fail()
                return
            }
            styleBuffer += text
        } else {
            append(escapeText(text))
        }
    }

    // MARK: Output

    private func append(_ part: String) {
        guard !failed else { return }
        let bytes = part.utf8.count
        guard outputBytes + bytes <= maximumBytes else {
            fail()
            return
        }
        output += part
        outputBytes += bytes
    }

    private func fail() {
        guard !failed else { return }
        failed = true
        parser?.abortParsing()
    }
}

// MARK: - Values

private enum SanitizeValue {
    static func attribute(named name: String, raw: String) -> String? {
        guard raw.utf8.count <= 1_000_000 else { return nil }
        let lowered = raw.lowercased()
        for refused in [
            "javascript:",
            "vbscript:",
            "expression(",
            "-moz-binding",
            "behavior:",
            "<",
            ">",
            "\u{0}"
        ] {
            guard !lowered.contains(refused) else { return nil }
        }
        switch name {
        case "href", "xlink:href":
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#"), trimmed.count <= 1_024 else {
                return nil
            }
            return trimmed
        case "style":
            return style(raw)
        case "viewBox":
            guard viewBox(raw) != nil else { return nil }
            return raw
        case "width", "height":
            guard validLength(raw) != nil else { return nil }
            return raw
        default:
            // Presentation attributes are CSS values. A CSS escape can hide
            // a `url(` from the literal check, so refuse any backslash.
            guard !raw.contains("\\") else { return nil }
            guard localURLsOnly(raw) else { return nil }
            return raw
        }
    }

    /// A CSS declaration list with unknown properties removed.
    static func style(_ raw: String) -> String? {
        var declarations: [String] = []
        for part in raw.split(separator: ";") {
            let pieces = part.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            let property = pieces[0]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard SVGWhitelist.cssProperties.contains(property) else {
                continue
            }
            let value = pieces[1].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty,
                  value.utf8.count <= 4_096,
                  safeDeclarationValue(value) else {
                continue
            }
            declarations.append("\(property): \(value)")
        }
        return declarations.isEmpty
            ? nil
            : declarations.joined(separator: "; ")
    }

    /// A whole stylesheet survives only when every construct in it is inert
    /// A whole stylesheet survives only when every construct in it is inert,
    /// rewritten so every selector can match only this SVG's root or its
    /// descendants.
    ///
    /// An SVG embedded inline shares the HTML document's style scope, so an
    /// unscoped rule such as `body { display: none }` would hide the entire
    /// exported page. Rewriting selectors keeps the diagram's own styling
    /// (Graphviz relies on a generated `text, [fill="black"]` rule) without
    /// letting any rule reach the host document.
    static func stylesheet(_ css: String, rootID: String?) -> String? {
        guard !css.isEmpty, css.utf8.count <= 512 * 1024 else { return nil }
        guard let rootID, !rootID.isEmpty else { return nil }
        let lowered = css.lowercased()
        for refused in [
            "@import",
            "expression(",
            "javascript:",
            "vbscript:",
            "-moz-binding",
            "behavior:",
            "<",
            "\\",
            "\u{0}"
        ] {
            guard !lowered.contains(refused) else { return nil }
        }
        guard localURLsOnly(css) else { return nil }
        guard let stripped = removingComments(css) else { return nil }
        let chars = Array(stripped)
        var index = 0
        return scopedRules(chars, index: &index, end: chars.count, rootID: rootID)
    }

    /// Rewrites every style rule in the sheet to select only the root or its
    /// descendants. Container at-rules (`@media`, `@supports`, `@layer`, …)
    /// are rewritten recursively; at-rules with no selectors (`@keyframes`,
    /// `@font-face`, …) pass unchanged. Any other at-rule rejects the sheet.
    private static func scopedRules(
        _ chars: [Character],
        index: inout Int,
        end: Int,
        rootID: String
    ) -> String? {
        var output = ""
        while index < end {
            var prelude = ""
            var foundBrace = false
            while index < end {
                let character = chars[index]
                if character == "{" {
                    foundBrace = true
                    index += 1
                    break
                }
                if character == ";" {
                    index += 1
                    break
                }
                prelude.append(character)
                index += 1
            }
            let trimmed = prelude.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !foundBrace {
                // A statement at-rule: `@import`, `@charset`, `@namespace`.
                // None is safe or needed here.
                if trimmed.isEmpty { continue }
                return nil
            }
            guard let bodyEnd = matchingBrace(chars, from: index, end: end)
            else { return nil }
            let body = String(chars[index..<bodyEnd])
            if trimmed.hasPrefix("@") {
                switch atRuleName(trimmed) {
                case "media", "supports", "layer", "container", "document",
                     "starting-style":
                    var innerIndex = index
                    guard let inner = scopedRules(
                        chars,
                        index: &innerIndex,
                        end: bodyEnd,
                        rootID: rootID
                    ) else { return nil }
                    output += "\(trimmed){\(inner)}"
                case "keyframes", "-webkit-keyframes", "-moz-keyframes",
                     "font-face", "page", "property", "counter-style",
                     "font-feature-values":
                    // These carry no element selectors.
                    output += "\(trimmed){\(body)}"
                default:
                    return nil
                }
            } else {
                let selectors = splitSelectors(trimmed)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard !selectors.isEmpty,
                      !selectors.contains(where: \.isEmpty) else {
                    return nil
                }
                let scoped = selectors.map {
                    scopedSelector($0, rootID: rootID)
                }
                output += scoped.joined(separator: ",") + "{\(body)}"
            }
            index = bodyEnd + 1
        }
        return output
    }

    private static func atRuleName(_ prelude: String) -> String {
        let name = prelude.dropFirst()
            .prefix(while: { !$0.isWhitespace && $0 != "(" && $0 != ":" })
        return name.lowercased()
    }

    /// Prefixes one selector so it can match only the scoped root. A selector
    /// whose first compound is the root element (`svg`) or `:root` addresses
    /// the root itself; prefixing it as a descendant would never match.
    private static func scopedSelector(
        _ selector: String,
        rootID: String
    ) -> String {
        let scope = "#" + rootID
        if selector == ":root" { return scope }
        if selector.hasPrefix(":root") {
            let after = selector.index(selector.startIndex, offsetBy: 5)
            return scope + selector[after...]
        }
        if selector == "svg" { return scope }
        if selector.hasPrefix("svg") {
            let after = selector.index(selector.startIndex, offsetBy: 3)
            let next = selector[after]
            if next == "." || next == "#" || next == "[" || next == ":"
                || next == " " || next == "\t" || next == "\n"
                || next == "\r" || next == ">" || next == "+"
                || next == "~" {
                return scope + selector[after...]
            }
        }
        return scope + " " + selector
    }

    /// The index of the `}` that closes the `{` just before `from`.
    private static func matchingBrace(
        _ chars: [Character],
        from: Int,
        end: Int
    ) -> Int? {
        var depth = 1
        var index = from
        var quote: Character?
        while index < end {
            let character = chars[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// Splits a selector list on commas outside parentheses, brackets, and
    /// strings.
    private static func splitSelectors(_ list: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for character in list {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                current.append(character)
            case "(", "[":
                depth += 1
                current.append(character)
            case ")", "]":
                depth = max(0, depth - 1)
                current.append(character)
            case "," where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    private static func removingComments(_ css: String) -> String? {
        var result = ""
        var index = css.startIndex
        while index < css.endIndex {
            if css[index] == "/", css.index(after: index) < css.endIndex,
               css[css.index(after: index)] == "*" {
                guard let close = css.range(
                    of: "*/",
                    range: css.index(index, offsetBy: 2)..<css.endIndex
                ) else { return nil }
                // A comment is not a token separator inside a selector.
                result.append(" ")
                index = close.upperBound
                continue
            }
            result.append(css[index])
            index = css.index(after: index)
        }
        return result
    }

    /// A four-number `viewBox` with a positive extent.
    static func viewBox(_ raw: String) -> (width: Double, height: Double)? {
        let tokens = raw.split(
            whereSeparator: { $0 == "," || $0.isWhitespace }
        )
        guard tokens.count == 4 else { return nil }
        let parts = tokens.compactMap { Double($0) }
        guard parts.count == 4,
              parts.allSatisfy({ $0.isFinite }),
              parts[2] > 0, parts[3] > 0 else {
            return nil
        }
        return (parts[2], parts[3])
    }

    /// A positive length with an optional `%` or `px` suffix. Percentages are
    /// legal attributes but are not an intrinsic size.
    static func validLength(_ raw: String) -> Double? {
        var value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasSuffix("%") {
            value.removeLast()
        }
        if value.hasSuffix("px") {
            value.removeLast(2)
        }
        guard let number = Double(value), number.isFinite, number > 0 else {
            return nil
        }
        return number
    }

    /// A positive point length with an optional `px` suffix. A percentage has
    /// no intrinsic size and returns `nil`.
    static func length(_ raw: String) -> Double? {
        var value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.hasSuffix("%") else { return nil }
        if value.hasSuffix("px") {
            value.removeLast(2)
        }
        guard let number = Double(value), number.isFinite, number > 0 else {
            return nil
        }
        return number
    }

    private static func safeDeclarationValue(_ value: String) -> Bool {
        let lowered = value.lowercased()
        for refused in [
            "javascript:",
            "vbscript:",
            "expression(",
            "-moz-binding",
            "behavior:",
            "@import",
            "<",
            ">",
            "\\",
            "\u{0}"
        ] {
            guard !lowered.contains(refused) else { return false }
        }
        return localURLsOnly(value)
    }

    /// True when every image reference points inside the document.
    ///
    /// `url(...)` is not the only way CSS names a resource: `image-set()`
    /// takes bare quoted strings, and a quoted `https://…` there would
    /// otherwise pass the sanitizer while loading a remote image.
    static func localURLsOnly(_ value: String) -> Bool {
        var search = value[...]
        while let range = search.range(of: "url(", options: .caseInsensitive) {
            guard let close = search[range.upperBound...]
                .firstIndex(of: ")") else {
                return false
            }
            var inner = String(search[range.upperBound..<close])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            inner = inner.trimmingCharacters(
                in: CharacterSet(charactersIn: "\"'")
            )
            guard inner.hasPrefix("#"), inner.count <= 1_024 else {
                return false
            }
            search = search[search.index(after: close)...]
        }
        var imageSetSearch = value[...]
        while let range = imageSetSearch.range(
            of: "image-set(",
            options: .caseInsensitive
        ) {
            guard let close = matchingParenthesis(
                in: imageSetSearch,
                from: range.upperBound
            ) else { return false }
            let inner = imageSetSearch[range.upperBound..<close]
            guard quotedSourcesAreLocal(inner) else { return false }
            imageSetSearch = imageSetSearch[
                imageSetSearch.index(after: close)...
            ]
        }
        return true
    }

    /// Every quoted string inside an `image-set()` argument is an image
    /// source; each one must be a local fragment.
    private static func quotedSourcesAreLocal(_ inner: Substring) -> Bool {
        var probe = inner.startIndex
        while probe < inner.endIndex {
            let character = inner[probe]
            guard character == "\"" || character == "'" else {
                probe = inner.index(after: probe)
                continue
            }
            let quote = character
            var end = inner.index(after: probe)
            while end < inner.endIndex, inner[end] != quote {
                end = inner.index(after: end)
            }
            guard end < inner.endIndex else { return false }
            let target = inner[inner.index(after: probe)..<end]
                .trimmingCharacters(in: .whitespaces)
            guard target.hasPrefix("#"), target.count <= 1_024 else {
                return false
            }
            probe = inner.index(after: end)
        }
        return true
    }

    private static func matchingParenthesis(
        in text: Substring,
        from start: Substring.Index
    ) -> Substring.Index? {
        var depth = 1
        var index = start
        var quote: Character?
        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

// MARK: - Escaping

private func escapeText(_ value: String) -> String {
    var result = value
    result = result.replacingOccurrences(of: "&", with: "&amp;")
    result = result.replacingOccurrences(of: "<", with: "&lt;")
    result = result.replacingOccurrences(of: ">", with: "&gt;")
    return result
}

private func escapeAttribute(_ value: String) -> String {
    var result = escapeText(value)
    result = result.replacingOccurrences(of: "\"", with: "&quot;")
    result = result.replacingOccurrences(of: "'", with: "&#39;")
    return result
}
