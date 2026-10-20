import AppKit
import Foundation
import SonovoCore

/// Retains one text view and controller per open Markdown document.
///
/// Tab and mode switches hide the view; they never destroy it. That keeps the
/// text view alive as an undo target for the document's `UndoManager`.
@MainActor
final class MarkdownEditorCache {
    static let shared = MarkdownEditorCache()

    struct Entry {
        let textView: NSTextView
        let scrollView: NSScrollView
        let controller: MarkdownEditorController
    }

    private var entries: [UUID: Entry] = [:]

    var count: Int { entries.count }

    func entry(
        for document: MarkdownDocument,
        parseService: MarkdownParseService,
        parseDebounce: TimeInterval = 0.12
    ) -> Entry {
        if let existing = entries[document.id] {
            return existing
        }

        let controller = MarkdownEditorController(
            document: document,
            parseService: parseService,
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

    func cachedEntry(for id: UUID) -> Entry? {
        entries[id]
    }

    func remove(for id: UUID) {
        entries.removeValue(forKey: id)
    }
}
