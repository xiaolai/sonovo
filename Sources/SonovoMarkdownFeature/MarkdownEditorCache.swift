import AppKit
import Foundation
import SonovoMarkdownEngine

/// Retains one text view and controller per open Markdown document.
///
/// Tab and mode switches hide the view; they never destroy it. That keeps the
/// text view alive as an undo target for the document's `UndoManager`.
@MainActor
package final class MarkdownEditorCache {
    package static let shared = MarkdownEditorCache()

    package struct Entry {
        package let textView: NSTextView
        package let scrollView: NSScrollView
        package let controller: MarkdownEditorController
    }

    private var entries: [UUID: Entry] = [:]

    package var count: Int { entries.count }

    package func entry(
        for document: MarkdownDocument,
        parseCoordinator: MarkdownParseCoordinator,
        parseDebounce: TimeInterval = 0.12
    ) -> Entry {
        if let existing = entries[document.id] {
            return existing
        }

        let controller = MarkdownEditorController(
            document: document,
            parseCoordinator: parseCoordinator,
            parseDebounce: parseDebounce
        )
        let entry = Entry(
            textView: controller.textView,
            scrollView: controller.scrollView,
            controller: controller
        )
        entries[document.id] = entry
        return entry
    }

    package func cachedEntry(for id: UUID) -> Entry? {
        entries[id]
    }

    package func remove(for id: UUID) {
        entries.removeValue(forKey: id)?.controller.detach()
    }
}
