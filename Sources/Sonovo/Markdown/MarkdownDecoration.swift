import AppKit

/// One semantic decoration over a source range.
///
/// Each layer owns a disjoint set of text-storage attribute keys, so removing
/// one layer cannot erase another. The compositor enforces that ownership: a
/// decoration that names a key its layer does not own is ignored.
struct MarkdownDecoration {
    enum Layer: Int, CaseIterable {
        /// Foreground dimming outside the focused block. Lowest precedence.
        case focus = 0
        /// Cell background. Loses to lint on foreground, owns only background.
        case cell = 1
        /// Lint severity. Wins over syntax color and focus dimming.
        case lint = 2

        var ownedKeys: [NSAttributedString.Key] {
            switch self {
            case .focus:
                return [.foregroundColor]
            case .cell:
                return [.backgroundColor]
            case .lint:
                return [.foregroundColor, .underlineStyle, .underlineColor]
            }
        }
    }

    let layer: Layer
    let range: NSRange
    let attributes: [NSAttributedString.Key: Any]
}

/// Decorations grouped by layer. Empty layers are the normal state when the
/// corresponding feature is off.
struct MarkdownDecorationSet {
    var focus: [MarkdownDecoration] = []
    var cell: [MarkdownDecoration] = []
    var lint: [MarkdownDecoration] = []

    static var empty: MarkdownDecorationSet { MarkdownDecorationSet() }

    var all: [MarkdownDecoration] { focus + cell + lint }
}

/// Applies syntax highlighting and the semantic decoration layers in one
/// editing pass over the affected range.
///
/// The compositor resets every owned key to its base value once, then applies
/// layers in precedence order: syntax, focus, cell, lint. It never uses
/// `NSLayoutManager` temporary attributes; the editor is TextKit 2, and every
/// change goes through the text storage so undo and layout stay consistent.
enum MarkdownDecorationCompositor {
    /// Keys the syntax highlighter owns. It is the only layer that sets fonts.
    static let syntaxKeys: [NSAttributedString.Key] = [
        .font,
        .foregroundColor,
        .backgroundColor
    ]

    static func apply(
        syntax: (NSTextStorage) -> Void,
        decorations: MarkdownDecorationSet,
        to storage: NSTextStorage,
        affectedRange: NSRange,
        baseAttributes: [NSAttributedString.Key: Any]
    ) {
        storage.beginEditing()
        defer { storage.endEditing() }

        for key in allOwnedKeys {
            if let value = baseAttributes[key] {
                storage.addAttribute(
                    key,
                    value: value,
                    range: affectedRange
                )
            } else {
                storage.removeAttribute(key, range: affectedRange)
            }
        }

        syntax(storage)

        let ordered = decorations.all.sorted {
            $0.layer.rawValue < $1.layer.rawValue
        }
        for decoration in ordered {
            let clipped = NSIntersectionRange(
                decoration.range,
                affectedRange
            )
            guard clipped.length > 0 else { continue }
            let owned = Set(decoration.layer.ownedKeys)
            for (key, value) in decoration.attributes where owned.contains(key) {
                storage.addAttribute(key, value: value, range: clipped)
            }
        }
    }

    private static var allOwnedKeys: [NSAttributedString.Key] {
        var keys = syntaxKeys
        for layer in MarkdownDecoration.Layer.allCases {
            for key in layer.ownedKeys where !keys.contains(key) {
                keys.append(key)
            }
        }
        return keys
    }
}
