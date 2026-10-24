import AppKit
import SwiftUI

/// Limits a theme may tune within. Values outside these ranges are clamped
/// and reported, so a hand-edited file cannot produce an unreadable document.
enum MarkdownThemeLimits {
    static let bodySize: ClosedRange<Double> = 12...24
    static let bodyLineSpacing: ClosedRange<Double> = 0...20
    static let paragraphIndent: ClosedRange<Double> = 0...3
    static let measure: ClosedRange<Double> = 420...900
    static let headingSize: ClosedRange<Double> = 10...72
    static let headingTopPadding: ClosedRange<Double> = 0...60
    static let codeSize: ClosedRange<Double> = 10...20
    static let codeLineSpacing: ClosedRange<Double> = 0...12
    static let tableSize: ClosedRange<Double> = 10...22
    static let captionSize: ClosedRange<Double> = 8...16
    static let blockSpacing: ClosedRange<Double> = 4...48
    static let pagePadding: ClosedRange<Double> = 8...80
    static let codePadding: ClosedRange<Double> = 4...32
    static let codeRadius: ClosedRange<Double> = 0...20
}

enum MarkdownThemeError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchema(Int)
    case invalidIdentifier(String)
    case missingIdentifier
    case missingName
    case missingBase(String)
    case cycle(String)
    case unreadable(String)
    case invalidJSON(String)
    case invalidValue(String)
    case invalidColor(String)

    var description: String {
        switch self {
        case .unsupportedSchema(let version):
            return "Theme schema version \(version) is not supported."
        case .invalidIdentifier(let id):
            return "Theme id \"\(id)\" must use lowercase letters, digits, and hyphens."
        case .missingIdentifier:
            return "Theme is missing an id."
        case .missingName:
            return "Theme is missing a name."
        case .missingBase(let id):
            return "Theme extends \"\(id)\", which was not found."
        case .cycle(let id):
            return "Theme inheritance loops through \"\(id)\"."
        case .unreadable(let message):
            return "Theme could not be read: \(message)"
        case .invalidJSON(let message):
            return "Theme JSON is invalid: \(message)"
        case .invalidValue(let message):
            return "Theme value is invalid: \(message)"
        case .invalidColor(let value):
            return "Color \"\(value)\" is not #RRGGBB or #RRGGBBAA."
        }
    }
}

enum ThemeFontDesign: String, Sendable {
    case serif
    case sans
    case mono

    var swiftUI: Font.Design {
        switch self {
        case .serif: .serif
        case .sans: .default
        case .mono: .monospaced
        }
    }
}

/// A font stack. The first installed family wins; otherwise the system font
/// in the requested design is used, so a missing font never breaks a theme.
struct ThemeFont: Equatable, Sendable {
    let families: [String]
    let design: ThemeFontDesign

    private static let installedFamilies = Set(
        NSFontManager.shared.availableFontFamilies
    )

    var resolvedFamily: String? {
        families.first { family in
            Self.installedFamilies.contains(family)
                || NSFontManager.shared.font(
                    withFamily: family,
                    traits: [],
                    weight: 5,
                    size: 12
                ) != nil
        }
    }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let base: Font
        if let family = resolvedFamily {
            base = .custom(family, size: size)
        } else {
            base = .system(size: size, design: design.swiftUI)
        }
        return base.weight(weight)
    }
}

struct ThemeColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8,
              let number = UInt64(value, radix: 16) else {
            return nil
        }
        if value.count == 6 {
            red = Double((number >> 16) & 0xFF) / 255
            green = Double((number >> 8) & 0xFF) / 255
            blue = Double(number & 0xFF) / 255
            alpha = 1
        } else {
            red = Double((number >> 24) & 0xFF) / 255
            green = Double((number >> 16) & 0xFF) / 255
            blue = Double((number >> 8) & 0xFF) / 255
            alpha = Double(number & 0xFF) / 255
        }
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red)
            + 0.7152 * linear(green)
            + 0.0722 * linear(blue)
    }

    /// Composites this colour over an opaque background. Contrast is
    /// meaningless for a transparent text colour unless the alpha is applied
    /// first, so `#00000000` cannot masquerade as black.
    func flattened(over background: ThemeColor) -> ThemeColor {
        guard alpha < 1 else { return self }
        return ThemeColor(
            red: red * alpha + background.red * (1 - alpha),
            green: green * alpha + background.green * (1 - alpha),
            blue: blue * alpha + background.blue * (1 - alpha),
            alpha: 1
        )
    }

    func contrast(with background: ThemeColor) -> Double {
        let backdrop = background.alpha < 1
            ? background.flattened(
                over: ThemeColor(red: 1, green: 1, blue: 1, alpha: 1)
            )
            : background
        let foreground = flattened(over: backdrop)
        let first = foreground.luminance
        let second = backdrop.luminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}

struct ThemePalette: Equatable, Sendable {
    let paper: ThemeColor
    let ink: ThemeColor
    let secondaryInk: ThemeColor
    let link: ThemeColor
    let codeGround: ThemeColor
    let codeInk: ThemeColor
    let quoteBar: ThemeColor
    let rule: ThemeColor
    let tableGround: ThemeColor
    let warning: ThemeColor
}

/// A fully resolved reading theme. Every value is validated and clamped; the
/// viewer never reads a raw theme file.
struct MarkdownTheme: Equatable, Sendable, Identifiable {
    let id: String
    let name: String

    let bodyFont: ThemeFont
    let uiFont: ThemeFont
    let bodySize: CGFloat
    let bodyLineSpacing: CGFloat
    let paragraphIndent: CGFloat
    let measure: CGFloat

    let headingFont: ThemeFont
    let headingSizes: [CGFloat]
    let headingTopPaddings: [CGFloat]

    let codeFont: ThemeFont
    let codeSize: CGFloat
    let codeLineSpacing: CGFloat
    let tableSize: CGFloat
    let captionSize: CGFloat

    let blockSpacing: CGFloat
    let pagePadding: CGFloat
    let codePadding: CGFloat
    let codeRadius: CGFloat

    let light: ThemePalette
    let dark: ThemePalette

    /// Non-fatal problems, such as a clamped value or a contrast warning.
    let warnings: [String]

    func palette(for scheme: ColorScheme) -> ThemePalette {
        scheme == .dark ? dark : light
    }

    func headingSize(_ level: Int) -> CGFloat {
        headingSizes[min(max(level, 1), headingSizes.count) - 1]
    }

    func headingTopPadding(_ level: Int) -> CGFloat {
        headingTopPaddings[min(max(level, 1), headingTopPaddings.count) - 1]
    }

    /// Reader overrides. Zero means "use the theme's own value".
    func withOverrides(bodySize: Double, measure: Double) -> MarkdownTheme {
        let size = bodySize > 0
            ? CGFloat(
                min(
                    max(bodySize, MarkdownThemeLimits.bodySize.lowerBound),
                    MarkdownThemeLimits.bodySize.upperBound
                )
            )
            : self.bodySize
        let width = measure > 0
            ? CGFloat(
                min(
                    max(measure, MarkdownThemeLimits.measure.lowerBound),
                    MarkdownThemeLimits.measure.upperBound
                )
            )
            : self.measure
        guard size != self.bodySize || width != self.measure else {
            return self
        }
        return MarkdownTheme(
            id: id,
            name: name,
            bodyFont: bodyFont,
            uiFont: uiFont,
            bodySize: size,
            bodyLineSpacing: bodyLineSpacing,
            paragraphIndent: paragraphIndent,
            measure: width,
            headingFont: headingFont,
            headingSizes: headingSizes,
            headingTopPaddings: headingTopPaddings,
            codeFont: codeFont,
            codeSize: codeSize,
            codeLineSpacing: codeLineSpacing,
            tableSize: tableSize,
            captionSize: captionSize,
            blockSpacing: blockSpacing,
            pagePadding: pagePadding,
            codePadding: codePadding,
            codeRadius: codeRadius,
            light: light,
            dark: dark,
            warnings: warnings
        )
    }
}

struct MarkdownThemeCatalog: Sendable {
    let themes: [MarkdownTheme]
    let issues: [String]

    static let empty = MarkdownThemeCatalog(themes: [], issues: [])
}

// MARK: - Store

/// Loads built-in and user themes. Built-ins are required resources; user
/// themes live in Application Support and never execute code.
@MainActor
final class MarkdownThemeStore {
    static let shared = MarkdownThemeStore()

    static let builtInOrder = ["paper", "book", "editorial", "draft"]
    static let defaultID = "paper"
    static let schemaVersion = 1

    private let bundle: Bundle
    private let userDirectory: URL
    private var themeCache: [String: MarkdownTheme] = [:]
    private var dictionaryCache: [String: [String: Any]] = [:]

    init(
        bundle: Bundle = .module,
        userDirectory: URL = MarkdownThemeStore.defaultUserDirectory
    ) {
        self.bundle = bundle
        self.userDirectory = userDirectory
    }

    static var defaultUserDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Sonovo", isDirectory: true)
        .appendingPathComponent("ReadingThemes", isDirectory: true)
    }

    var themesDirectory: URL { userDirectory }

    func reload() {
        themeCache.removeAll()
        dictionaryCache.removeAll()
    }

    func defaultTheme() -> MarkdownTheme {
        if let cached = themeCache[Self.defaultID] { return cached }
        guard let loaded = try? loadTheme(id: Self.defaultID) else {
            preconditionFailure(
                "The built-in \"paper\" reading theme is missing or invalid."
            )
        }
        themeCache[Self.defaultID] = loaded
        return loaded
    }

    /// The requested theme, falling back to the default when a user file is
    /// missing or malformed. Settings reports the reason from `catalog()`.
    func theme(id: String) -> MarkdownTheme {
        if let cached = themeCache[id] { return cached }
        if let loaded = try? loadTheme(id: id) {
            themeCache[id] = loaded
            return loaded
        }
        return defaultTheme()
    }

    func catalog() -> MarkdownThemeCatalog {
        var themes: [MarkdownTheme] = []
        var issues: [String] = []

        for id in Self.builtInOrder {
            do {
                themes.append(try loadTheme(id: id))
            } catch {
                issues.append("\(id): \(error)")
            }
        }

        let builtInIDs = Set(Self.builtInOrder)
        for url in userThemeFiles() {
            let id = url.deletingPathExtension().lastPathComponent
            if builtInIDs.contains(id) {
                issues.append("\(id): a user theme cannot replace a built-in theme.")
                continue
            }
            do {
                themes.append(try loadTheme(id: id))
            } catch {
                issues.append("\(id): \(error)")
            }
        }
        return MarkdownThemeCatalog(themes: themes, issues: issues)
    }

    func duplicateTheme(id: String) throws -> String {
        guard let dictionary = try resolvedDictionary(id: id, visited: []),
              let sourceName = dictionary["name"] as? String else {
            throw MarkdownThemeError.missingBase(id)
        }
        try FileManager.default.createDirectory(
            at: userDirectory,
            withIntermediateDirectories: true
        )

        let newID = uniqueID(base: "\(id)-copy")
        let document = DerivedTheme(
            schemaVersion: Self.schemaVersion,
            id: newID,
            name: "\(sourceName) Copy",
            extends: id
        )
        let data = try JSONEncoder.pretty.encode(document)
        try data.write(
            to: userDirectory.appendingPathComponent("\(newID).json"),
            options: .atomic
        )
        reload()
        return newID
    }

    func openThemesFolder() {
        try? FileManager.default.createDirectory(
            at: userDirectory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(userDirectory)
    }

    // MARK: Loading

    private func loadTheme(id: String) throws -> MarkdownTheme {
        guard let dictionary = try resolvedDictionary(id: id, visited: []) else {
            throw MarkdownThemeError.missingBase(id)
        }
        let document: ResolvedDocument
        do {
            let data = try JSONSerialization.data(
                withJSONObject: dictionary,
                options: []
            )
            document = try JSONDecoder().decode(ResolvedDocument.self, from: data)
        } catch let error as MarkdownThemeError {
            throw error
        } catch {
            throw MarkdownThemeError.invalidJSON(error.localizedDescription)
        }
        return try resolve(document)
    }

    /// Reads a theme's raw JSON, resolves `extends`, and deep-merges the base
    /// under the child. Returns nil when the id is unknown.
    private func resolvedDictionary(
        id: String,
        visited: Set<String>
    ) throws -> [String: Any]? {
        guard !visited.contains(id) else {
            throw MarkdownThemeError.cycle(id)
        }
        // An id becomes a file name. Reject anything that is not a plain
        // slug before touching the filesystem, including `extends` values.
        guard Self.isValidIdentifier(id) else {
            throw MarkdownThemeError.invalidIdentifier(id)
        }
        guard let raw = try rawObject(id: id) else { return nil }
        return try resolvedDictionary(
            raw: raw,
            id: id,
            visited: visited.union([id])
        )
    }

    private func resolvedDictionary(
        raw: [String: Any],
        id: String,
        visited: Set<String>
    ) throws -> [String: Any] {
        guard let version = raw["schemaVersion"] as? Int,
              version == Self.schemaVersion else {
            throw MarkdownThemeError.unsupportedSchema(
                raw["schemaVersion"] as? Int ?? -1
            )
        }
        guard let documentID = raw["id"] as? String else {
            throw MarkdownThemeError.missingIdentifier
        }
        guard documentID == id else {
            throw MarkdownThemeError.invalidIdentifier(
                "\(documentID) (file name is \(id))"
            )
        }
        guard Self.isValidIdentifier(documentID) else {
            throw MarkdownThemeError.invalidIdentifier(documentID)
        }
        guard let name = raw["name"] as? String,
              !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MarkdownThemeError.missingName
        }

        // A document without an explicit base inherits the default, except
        // the default itself. This keeps user themes short and validated.
        // A wrong-typed value is a schema error, not a silent lack of base.
        let baseID: String?
        if let value = raw["extends"] {
            guard let explicit = value as? String else {
                throw MarkdownThemeError.invalidValue(
                    "extends must be a string."
                )
            }
            baseID = explicit
        } else {
            baseID = id == Self.defaultID ? nil : Self.defaultID
        }

        var merged: [String: Any]
        if let baseID {
            guard let base = try resolvedDictionary(
                id: baseID,
                visited: visited
            ) else {
                throw MarkdownThemeError.missingBase(baseID)
            }
            merged = deepMerge(base, raw)
        } else {
            merged = raw
        }
        merged.removeValue(forKey: "extends")
        merged["id"] = id
        merged["name"] = name
        return merged
    }

    private func rawObject(id: String) throws -> [String: Any]? {
        if let cached = dictionaryCache[id] { return cached }
        guard let text = rawText(id: id) else { return nil }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw MarkdownThemeError.invalidJSON(
                "\(id).json is not a JSON object."
            )
        }
        dictionaryCache[id] = dictionary
        return dictionary
    }

    private func rawText(id: String) -> String? {
        if let url = bundle.url(
            forResource: id,
            withExtension: "json",
            subdirectory: "ReadingThemes"
        ), let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        let url = userDirectory.appendingPathComponent("\(id).json")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func userThemeFiles() -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: userDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return contents
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func uniqueID(base: String) -> String {
        let existing = Set(
            Self.builtInOrder + userThemeFiles().map {
                $0.deletingPathExtension().lastPathComponent
            }
        )
        if !existing.contains(base) { return base }
        var index = 2
        while existing.contains("\(base)-\(index)") {
            index += 1
        }
        return "\(base)-\(index)"
    }

    // MARK: Validation

    private func resolve(_ document: ResolvedDocument) throws -> MarkdownTheme {
        var warnings: [String] = []

        func clamp(
            _ value: Double,
            _ range: ClosedRange<Double>,
            _ label: String
        ) -> CGFloat {
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            if clamped != value {
                warnings.append(
                    "\(label) \(value) was clamped to \(clamped)."
                )
            }
            return CGFloat(clamped)
        }

        guard document.typography.headingSizes.count == 6 else {
            throw MarkdownThemeError.invalidValue(
                "headingSizes must contain six values."
            )
        }
        guard document.typography.headingTopPadding.count == 6 else {
            throw MarkdownThemeError.invalidValue(
                "headingTopPadding must contain six values."
            )
        }
        guard let bodyDesign = ThemeFontDesign(
            rawValue: document.typography.bodyFont.design
        ), let uiDesign = ThemeFontDesign(
            rawValue: document.typography.uiFont.design
        ), let headingDesign = ThemeFontDesign(
            rawValue: document.typography.headingFont.design
        ), let codeDesign = ThemeFontDesign(
            rawValue: document.typography.codeFont.design
        ) else {
            throw MarkdownThemeError.invalidValue(
                "Font design must be serif, sans, or mono."
            )
        }
        // An empty stack is intentional: it selects the system font in the
        // themed design. Paper uses it so the default rendering matches the
        // system serif and monospaced faces the viewer shipped with.

        let light = try palette(document.colors.light)
        let dark = try palette(document.colors.dark)
        let theme = MarkdownTheme(
            id: document.id,
            name: document.name,
            bodyFont: ThemeFont(
                families: document.typography.bodyFont.families,
                design: bodyDesign
            ),
            uiFont: ThemeFont(
                families: document.typography.uiFont.families,
                design: uiDesign
            ),
            bodySize: clamp(
                document.typography.bodySize,
                MarkdownThemeLimits.bodySize,
                "bodySize"
            ),
            bodyLineSpacing: clamp(
                document.typography.bodyLineSpacing,
                MarkdownThemeLimits.bodyLineSpacing,
                "bodyLineSpacing"
            ),
            paragraphIndent: clamp(
                document.typography.paragraphIndent,
                MarkdownThemeLimits.paragraphIndent,
                "paragraphIndent"
            ),
            measure: clamp(
                document.typography.measure,
                MarkdownThemeLimits.measure,
                "measure"
            ),
            headingFont: ThemeFont(
                families: document.typography.headingFont.families,
                design: headingDesign
            ),
            headingSizes: document.typography.headingSizes.map {
                clamp($0, MarkdownThemeLimits.headingSize, "headingSize")
            },
            headingTopPaddings: document.typography.headingTopPadding.map {
                clamp($0, MarkdownThemeLimits.headingTopPadding, "headingTopPadding")
            },
            codeFont: ThemeFont(
                families: document.typography.codeFont.families,
                design: codeDesign
            ),
            codeSize: clamp(
                document.typography.codeSize,
                MarkdownThemeLimits.codeSize,
                "codeSize"
            ),
            codeLineSpacing: clamp(
                document.typography.codeLineSpacing,
                MarkdownThemeLimits.codeLineSpacing,
                "codeLineSpacing"
            ),
            tableSize: clamp(
                document.typography.tableSize,
                MarkdownThemeLimits.tableSize,
                "tableSize"
            ),
            captionSize: clamp(
                document.typography.captionSize,
                MarkdownThemeLimits.captionSize,
                "captionSize"
            ),
            blockSpacing: clamp(
                document.rhythm.blockSpacing,
                MarkdownThemeLimits.blockSpacing,
                "blockSpacing"
            ),
            pagePadding: clamp(
                document.rhythm.pagePadding,
                MarkdownThemeLimits.pagePadding,
                "pagePadding"
            ),
            codePadding: clamp(
                document.rhythm.codePadding,
                MarkdownThemeLimits.codePadding,
                "codePadding"
            ),
            codeRadius: clamp(
                document.rhythm.codeRadius,
                MarkdownThemeLimits.codeRadius,
                "codeRadius"
            ),
            light: light,
            dark: dark,
            warnings: []
        )
        warnings.append(contentsOf: contrastWarnings(for: theme))
        return MarkdownTheme(
            id: theme.id,
            name: theme.name,
            bodyFont: theme.bodyFont,
            uiFont: theme.uiFont,
            bodySize: theme.bodySize,
            bodyLineSpacing: theme.bodyLineSpacing,
            paragraphIndent: theme.paragraphIndent,
            measure: theme.measure,
            headingFont: theme.headingFont,
            headingSizes: theme.headingSizes,
            headingTopPaddings: theme.headingTopPaddings,
            codeFont: theme.codeFont,
            codeSize: theme.codeSize,
            codeLineSpacing: theme.codeLineSpacing,
            tableSize: theme.tableSize,
            captionSize: theme.captionSize,
            blockSpacing: theme.blockSpacing,
            pagePadding: theme.pagePadding,
            codePadding: theme.codePadding,
            codeRadius: theme.codeRadius,
            light: theme.light,
            dark: theme.dark,
            warnings: warnings
        )
    }

    private func palette(_ spec: PaletteSpec) throws -> ThemePalette {
        func color(_ value: String, _ label: String) throws -> ThemeColor {
            guard let color = ThemeColor(hex: value) else {
                throw MarkdownThemeError.invalidColor("\(label): \(value)")
            }
            return color
        }
        return ThemePalette(
            paper: try color(spec.paper, "paper"),
            ink: try color(spec.ink, "ink"),
            secondaryInk: try color(spec.secondaryInk, "secondaryInk"),
            link: try color(spec.link, "link"),
            codeGround: try color(spec.codeGround, "codeGround"),
            codeInk: try color(spec.codeInk, "codeInk"),
            quoteBar: try color(spec.quoteBar, "quoteBar"),
            rule: try color(spec.rule, "rule"),
            tableGround: try color(spec.tableGround, "tableGround"),
            warning: try color(spec.warning, "warning")
        )
    }

    private func contrastWarnings(for theme: MarkdownTheme) -> [String] {
        var warnings: [String] = []
        for (appearance, palette) in [("Light", theme.light), ("Dark", theme.dark)] {
            if palette.paper.alpha < 1 {
                warnings.append("\(appearance) paper must be opaque.")
            }
            if palette.codeGround.alpha < 1 {
                warnings.append("\(appearance) codeGround must be opaque.")
            }
            let pairs: [(String, ThemeColor, ThemeColor, Double)] = [
                ("text", palette.ink, palette.paper, 4.5),
                ("secondary text", palette.secondaryInk, palette.paper, 4.5),
                ("link", palette.link, palette.paper, 3.0),
                ("warning", palette.warning, palette.paper, 3.0),
                ("code text", palette.codeInk, palette.codeGround, 4.5)
            ]
            for (label, foreground, background, minimum) in pairs {
                let ratio = foreground.contrast(with: background)
                if ratio < minimum {
                    warnings.append(
                        String(
                            format: "%@ %@ contrast %.1f:1 is below %.1f:1.",
                            appearance,
                            label,
                            ratio,
                            minimum
                        )
                    )
                }
            }
        }
        return warnings
    }

    private static func isValidIdentifier(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64 else { return false }
        return id.allSatisfy {
            $0.isLowercase || $0.isNumber || $0 == "-"
        }
    }

    private func deepMerge(
        _ base: [String: Any],
        _ child: [String: Any]
    ) -> [String: Any] {
        var result = base
        for (key, value) in child {
            if let baseDictionary = result[key] as? [String: Any],
               let childDictionary = value as? [String: Any] {
                result[key] = deepMerge(baseDictionary, childDictionary)
            } else {
                result[key] = value
            }
        }
        return result
    }
}

// MARK: - Documents

private struct ResolvedDocument: Decodable {
    let id: String
    let name: String
    let typography: Typography
    let rhythm: Rhythm
    let colors: Colors
}

private struct Typography: Decodable {
    let bodyFont: FontSpec
    let uiFont: FontSpec
    let bodySize: Double
    let bodyLineSpacing: Double
    let paragraphIndent: Double
    let measure: Double
    let headingFont: FontSpec
    let headingSizes: [Double]
    let headingTopPadding: [Double]
    let codeFont: FontSpec
    let codeSize: Double
    let codeLineSpacing: Double
    let tableSize: Double
    let captionSize: Double
}

private struct FontSpec: Decodable {
    let families: [String]
    let design: String
}

private struct Rhythm: Decodable {
    let blockSpacing: Double
    let pagePadding: Double
    let codePadding: Double
    let codeRadius: Double
}

private struct Colors: Decodable {
    let light: PaletteSpec
    let dark: PaletteSpec
}

private struct PaletteSpec: Decodable {
    let paper: String
    let ink: String
    let secondaryInk: String
    let link: String
    let codeGround: String
    let codeInk: String
    let quoteBar: String
    let rule: String
    let tableGround: String
    let warning: String
}

private struct DerivedTheme: Encodable {
    let schemaVersion: Int
    let id: String
    let name: String
    let extends: String
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
