import AppKit
import SonovoTextEngine

package enum SyntaxTokenStyle {
    package nonisolated static func role(for kind: CodeTokenKind) -> AppTheme.SyntaxRole {
        switch kind {
        case .keyword: .keyword
        case .typeName: .typeName
        case .string: .string
        case .comment: .comment
        case .number: .number
        case .function: .function
        case .property: .property
        case .punctuation: .punctuation
        case .identifier: .identifier
        case .markup: .markup
        }
    }

}

package struct CodeLineLayout {

    package init(
        documentOffset: Int,
        rect: NSRect,
        text: String
    ) {
        self.documentOffset = documentOffset
        self.rect = rect
        self.text = text
    }

    package let documentOffset: Int
    package let rect: NSRect
    package let text: String
}
