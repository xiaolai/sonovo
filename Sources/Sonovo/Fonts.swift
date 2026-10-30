import AppKit
import CoreText
import SwiftUI

/// Font choices shared by the reading surfaces, the code editor, and the
/// terminal recommendation.
enum FontPreferences {
    static let chineseFaceKey = "sonovo.fonts.chineseFace"
    static let codeFamilyKey = "sonovo.fonts.codeFamily"
    static let readingFaceKey = "sonovo.fonts.readingFace"
    static let defaultChineseFace = "PingFang SC"

    /// The Chinese face used as a CoreText cascade for every reading and
    /// code font. `nil` means no cascade; the system fallback is used.
    static func chineseFaceName(
        defaults: UserDefaults = .standard
    ) -> String? {
        let raw = defaults.string(forKey: chineseFaceKey)
            ?? defaultChineseFace
        return ChineseFace.valid(fontName: raw)
    }

    /// The installed Nerd Font chosen for code. Empty means system mono.
    static func codeFamily(
        defaults: UserDefaults = .standard
    ) -> String {
        let raw = defaults.string(forKey: codeFamilyKey) ?? ""
        return AppFonts.isInstalled(raw) ? raw : ""
    }

    /// The Latin reading face. `theme` keeps each reading theme's own stack.
    static func readingFace(
        defaults: UserDefaults = .standard
    ) -> ReadingFace {
        let raw = defaults.string(forKey: readingFaceKey) ?? ""
        return ReadingFace(rawValue: raw)?.available ?? .theme
    }
}

/// The Latin faces a reader can choose without editing a theme file.
enum ReadingFace: String, CaseIterable, Identifiable {
    case theme
    case newYork
    case charter
    case georgia
    case sfProText

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .theme: "Follow theme"
        case .newYork: "New York"
        case .charter: "Charter"
        case .georgia: "Georgia"
        case .sfProText: "SF Pro Text"
        }
    }

    var families: [String] {
        switch self {
        case .theme, .newYork: []
        case .charter: ["Charter"]
        case .georgia: ["Georgia"]
        case .sfProText: ["SF Pro Text", "Helvetica Neue"]
        }
    }

    var design: ThemeFontDesign {
        switch self {
        case .theme, .newYork, .charter, .georgia: .serif
        case .sfProText: .sans
        }
    }

    var isAvailable: Bool {
        switch self {
        case .theme, .newYork: true
        default: AppFonts.isInstalled(families.first ?? "")
        }
    }

    var available: ReadingFace {
        isAvailable ? self : .theme
    }

    static var installed: [ReadingFace] {
        allCases.filter(\.isAvailable)
    }
}

/// The Chinese faces the app can set, following Tsundoku's choices: each
/// family is offered in its Simplified and Traditional cut, and only faces
/// this Mac can actually draw are offered.
enum ChineseFace: String, CaseIterable, Identifiable {
    case pingFangSC
    case pingFangTC
    case hiraginoGB
    case hiraginoCNS

    var id: String { rawValue }

    var fontName: String {
        switch self {
        case .pingFangSC: "PingFang SC"
        case .pingFangTC: "PingFang TC"
        case .hiraginoGB: "Hiragino Sans GB"
        case .hiraginoCNS: "Hiragino Sans CNS"
        }
    }

    var displayName: String {
        switch self {
        case .pingFangSC: "PingFang 简体"
        case .pingFangTC: "PingFang 繁體"
        case .hiraginoGB: "Hiragino Sans 简体"
        case .hiraginoCNS: "Hiragino Sans 繁體"
        }
    }

    /// An unknown name resolves to a substitute; comparing the returned
    /// family catches that instead of silently offering a font that lies.
    var isInstalled: Bool {
        let font = CTFontCreateWithName(
            fontName as CFString,
            AppTheme.TypeScale.body,
            nil
        )
        return (CTFontCopyFamilyName(font) as String) == fontName
    }

    static var installed: [ChineseFace] {
        allCases.filter(\.isInstalled)
    }

    /// A stored name made valid. An empty name means "no cascade"; an
    /// unknown or uninstalled name falls back to the default face.
    static func valid(fontName: String) -> String? {
        if fontName.isEmpty { return nil }
        if let face = allCases.first(where: { $0.fontName == fontName }),
           face.isInstalled {
            return face.fontName
        }
        return (allCases.first(where: \.isInstalled) ?? .pingFangSC).fontName
    }
}

/// The Nerd Font recommendation and the installed families this Mac can use.
enum NerdFonts {
    /// The researched recommendation for code and terminal work: tall
    /// x-height, distinct zero/one/letter shapes, ligatures, and an
    /// officially maintained Nerd Font build.
    static let recommendedFamily = "JetBrainsMono Nerd Font Mono"
    static let downloadPage = URL(
        string: "https://www.nerdfonts.com/font-downloads"
    )!
    static let recommendedDownload = URL(
        string: "https://github.com/ryanoasis/nerd-fonts/releases/latest/"
            + "download/JetBrainsMono.zip"
    )!
    static let installCommand =
        "brew install --cask font-jetbrains-mono-nerd-font"

    /// Installed Nerd Font families, recommended first. MesloLGS NF is
    /// included because many terminal setups install that name instead.
    static var installedFamilies: [String] {
        var families = NSFontManager.shared.availableFontFamilies.filter {
            let lowered = $0.lowercased()
            return lowered.contains("nerd font")
                || lowered.contains("meslolgs nf")
        }
        .sorted()
        if let index = families.firstIndex(of: recommendedFamily) {
            families.insert(families.remove(at: index), at: 0)
        }
        return families
    }

    static var isRecommendedInstalled: Bool {
        installedFamilies.contains(recommendedFamily)
    }
}

/// Builds concrete fonts. Every reading and code font carries the chosen
/// Chinese face as a CoreText cascade, so Latin keeps its face while Chinese
/// glyphs use PingFang or the selected alternative.
enum AppFonts {
    static func isInstalled(_ family: String) -> Bool {
        guard !family.isEmpty else { return false }
        if NSFontManager.shared.availableFontFamilies.contains(family) {
            return true
        }
        return NSFontManager.shared.font(
            withFamily: family,
            traits: [],
            weight: 5,
            size: AppTheme.TypeScale.body
        ) != nil
    }

    static func resolvedFamily(from families: [String]) -> String? {
        families.first(where: isInstalled)
    }

    /// The SwiftUI font for a reading theme.
    static func themedFont(
        families: [String],
        design: ThemeFontDesign,
        size: CGFloat,
        weight: Font.Weight = .regular
    ) -> Font {
        let base = baseFont(
            families: families,
            design: design,
            size: size,
            weight: weight
        )
        return Font(withChineseCascade(base, size: size))
    }

    /// The AppKit font for the code editor.
    static func codeFont(size: CGFloat, family: String) -> NSFont {
        let base: NSFont
        if !family.isEmpty, let chosen = NSFont(name: family, size: size) {
            base = chosen
        } else {
            base = NSFont.monospacedSystemFont(
                ofSize: size,
                weight: .regular
            )
        }
        return withChineseCascade(base, size: size)
    }

    static func baseFont(
        families: [String],
        design: ThemeFontDesign,
        size: CGFloat,
        weight: Font.Weight
    ) -> NSFont {
        if let family = resolvedFamily(from: families),
           let custom = customFont(family: family, size: size, weight: weight) {
            return custom
        }
        switch design {
        case .sans:
            return NSFont.systemFont(
                ofSize: size,
                weight: nsWeight(weight)
            )
        case .serif:
            let system = NSFont.systemFont(
                ofSize: size,
                weight: nsWeight(weight)
            )
            guard let descriptor = system.fontDescriptor
                .withDesign(.serif) else {
                return system
            }
            return NSFont(descriptor: descriptor, size: size) ?? system
        case .mono:
            // Reading code blocks follow the app's chosen code face.
            let family = FontPreferences.codeFamily()
            if !family.isEmpty,
               let chosen = NSFont(name: family, size: size) {
                return chosen
            }
            return NSFont.monospacedSystemFont(
                ofSize: size,
                weight: nsWeight(weight)
            )
        }
    }

    private static func customFont(
        family: String,
        size: CGFloat,
        weight: Font.Weight
    ) -> NSFont? {
        let descriptor = NSFontDescriptor(name: family, size: size)
            .addingAttributes([
                .traits: [
                    NSFontDescriptor.TraitKey.weight: nsWeight(weight).rawValue
                ]
            ])
        return NSFont(descriptor: descriptor, size: size)
            ?? NSFont(name: family, size: size)
    }

    /// Attaches the chosen Chinese face as a fallback. The fallback is a
    /// descriptor, not a second font run, so Latin stays in the primary face.
    static func withChineseCascade(_ font: NSFont, size: CGFloat) -> NSFont {
        guard let chinese = FontPreferences.chineseFaceName() else {
            return font
        }
        return cascadedFont(font, size: size, chinese: chinese)
    }

    /// The pure cascade step, exposed so tests can name the face instead of
    /// depending on the user's preference.
    static func cascadedFont(
        _ font: NSFont,
        size: CGFloat,
        chinese: String
    ) -> NSFont {
        let descriptor = NSFontDescriptor(name: chinese, size: size)
        let cascaded = font.fontDescriptor.addingAttributes([
            .cascadeList: [descriptor]
        ])
        return NSFont(descriptor: cascaded, size: size) ?? font
    }

    private static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        if weight == .ultraLight { return .ultraLight }
        if weight == .thin { return .thin }
        if weight == .light { return .light }
        if weight == .medium { return .medium }
        if weight == .semibold { return .semibold }
        if weight == .bold { return .bold }
        if weight == .heavy { return .heavy }
        if weight == .black { return .black }
        return .regular
    }
}
