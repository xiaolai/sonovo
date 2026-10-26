import SwiftUI
import SonovoCore

/// A GitHub alert written as `> [!NOTE]` in the first line of a block quote.
///
/// The source bytes are never changed. The marker is stripped only from the
/// projection, so the viewer and the export share one interpretation of the
/// same quote.
enum MarkdownAlertKind: String, CaseIterable, Sendable {
    case note
    case tip
    case important
    case warning
    case caution

    var marker: String { "[!\(rawValue)]" }
    var label: String { rawValue.capitalized }

    var icon: String {
        switch self {
        case .note: "info.circle"
        case .tip: "lightbulb"
        case .important: "exclamationmark.circle"
        case .warning: "exclamationmark.triangle"
        case .caution: "xmark.octagon"
        }
    }

    var color: Color {
        switch self {
        case .note: AppTheme.MarkdownChrome.Alerts.note
        case .tip: AppTheme.MarkdownChrome.Alerts.tip
        case .important: AppTheme.MarkdownChrome.Alerts.important
        case .warning: AppTheme.MarkdownChrome.Alerts.warning
        case .caution: AppTheme.MarkdownChrome.Alerts.caution
        }
    }

    /// The alert whose marker starts the quote's first text inline.
    static func kind(in blocks: [Block]) -> MarkdownAlertKind? {
        guard case .paragraph(let inlines, _) = blocks.first,
              case .text(let text, _) = inlines.first else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for kind in MarkdownAlertKind.allCases
        where trimmed.lowercased().hasPrefix(kind.marker) {
            return kind
        }
        return nil
    }

    /// The quote body with this marker removed from its first text inline.
    func strippingMarker(from blocks: [Block]) -> [Block] {
        guard !blocks.isEmpty,
              case .paragraph(var inlines, let range) = blocks[0],
              case .text(let text, let textRange) = inlines.first,
              let markerRange = text.range(
                  of: marker,
                  options: .caseInsensitive
              ) else {
            return blocks
        }
        var newText = text
        newText.removeSubrange(markerRange)
        while newText.first == " " || newText.first == "\t" {
            newText.removeFirst()
        }
        if newText.isEmpty {
            inlines.removeFirst()
        } else {
            inlines[0] = .text(newText, range: textRange)
        }
        var result = blocks
        if inlines.isEmpty {
            result.removeFirst()
        } else {
            result[0] = .paragraph(inlines: inlines, range: range)
        }
        return result
    }
}
