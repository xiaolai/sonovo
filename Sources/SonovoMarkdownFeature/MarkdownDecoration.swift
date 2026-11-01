import AppKit

/// One semantic decoration over a source range.
///
/// Each layer owns a disjoint set of text-storage attribute keys, so removing
/// one layer cannot erase another. The compositor enforces that ownership: a
/// decoration that names a key its layer does not own is ignored.
package struct MarkdownDecoration {
    package enum Layer: Int, CaseIterable {
        /// Foreground dimming outside the focused block. Lowest precedence.
        case focus = 0
        /// Cell background. Loses to selection and lint on its own keys.
        case cell = 1
        /// Secondary multi-cursor selection. Owns the background key and
        /// wins it over the cell layer (`cell < selection`), so a selection
        /// inside a highlighted cell shows the selection; moving it away
        /// restores the cell colour on the next pass.
        case selection = 2
        /// Lint severity. Wins over syntax colour and focus dimming.
        case lint = 3

        package var ownedKeys: [NSAttributedString.Key] {
            switch self {
            case .focus:
                return [.foregroundColor]
            case .cell:
                return [.backgroundColor]
            case .selection:
                return [.backgroundColor]
            case .lint:
                return [.foregroundColor, .underlineStyle, .underlineColor]
            }
        }
    }

    package let layer: Layer
    package let range: NSRange
    package let attributes: [NSAttributedString.Key: Any]
}

/// Decorations grouped by layer. Empty layers are the normal state when the
/// corresponding feature is off.
package struct MarkdownDecorationSet {
    package var focus: [MarkdownDecoration] = []
    package var cell: [MarkdownDecoration] = []
    package var lint: [MarkdownDecoration] = []
    package var selection: [MarkdownDecoration] = []

    package static var empty: MarkdownDecorationSet { MarkdownDecorationSet() }

    package var all: [MarkdownDecoration] { focus + cell + lint + selection }
}

/// Applies syntax highlighting and the semantic decoration layers in one
/// editing pass over the affected range.
///
/// The compositor resets every owned key to its base value once, then applies
/// layers in precedence order: syntax, focus, cell, lint. It never uses
/// `NSLayoutManager` temporary attributes; the editor is TextKit 2, and every
/// change goes through the text storage so undo and layout stay consistent.
package enum MarkdownDecorationCompositor {
    /// Keys the syntax highlighter owns. It is the only layer that sets fonts.
    package static let syntaxKeys: [NSAttributedString.Key] = [
        .font,
        .foregroundColor,
        .backgroundColor
    ]

    package static func apply(
        syntax: (NSTextStorage) -> Void,
        decorations: MarkdownDecorationSet,
        to storage: NSTextStorage,
        affectedRange: NSRange,
        fontRange: NSRange? = nil,
        baseAttributes: [NSAttributedString.Key: Any]
    ) {
        storage.beginEditing()
        defer { storage.endEditing() }

        let metricRange = fontRange ?? affectedRange
        for key in allOwnedKeys {
            // Font metrics are the only layer that changes layout. Keep them
            // inside the laid-out viewport so offscreen text cannot force a
            // layout that moves the viewport under the scroll position.
            let target = key == .font ? metricRange : affectedRange
            if let value = baseAttributes[key] {
                storage.addAttribute(
                    key,
                    value: value,
                    range: target
                )
            } else {
                storage.removeAttribute(key, range: target)
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
                let target = key == .font
                    ? NSIntersectionRange(clipped, metricRange)
                    : clipped
                guard target.length > 0 else { continue }
                storage.addAttribute(key, value: value, range: target)
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
