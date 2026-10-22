import Foundation

/// Retains one TextKit 2 surface per open code document.
///
/// A tab switch hides the view; it never destroys it. That keeps the undo
/// stack, cursor, and scroll position attached to the document, matching the
/// Markdown editor's contract.
@MainActor
final class CodeEditorCache {
    private var entries: [UUID: CodeEditorController] = [:]

    var count: Int { entries.count }

    func controller(
        for document: CodeDocument,
        settings: CodeEditorSettings = .load()
    ) -> CodeEditorController {
        if let existing = entries[document.id] {
            existing.updateSettings(settings)
            return existing
        }
        let controller = CodeEditorController(
            document: document,
            settings: settings
        )
        entries[document.id] = controller
        return controller
    }

    func cachedController(for id: UUID) -> CodeEditorController? {
        entries[id]
    }

    func remove(for id: UUID) {
        entries.removeValue(forKey: id)
    }
}
