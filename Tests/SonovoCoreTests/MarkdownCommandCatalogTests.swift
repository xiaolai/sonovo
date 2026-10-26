import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown command catalog")
struct MarkdownCommandCatalogTests {
    @Test("Every catalog entry has a title and appears once")
    func completeness() {
        let registry = MarkdownCommandRegistry()
        var seen = Set<MarkdownCommandKind>()
        for entry in MarkdownCommandCatalog.entries {
            #expect(!registry.title(for: entry.command).isEmpty)
            #expect(!entry.category.isEmpty)
            #expect(!seen.contains(entry.command))
            seen.insert(entry.command)
        }
    }

    @Test("The palette excludes argument-only commands")
    func excludesArgumentCommands() {
        let entries = MarkdownCommandCatalog.paletteEntries { _ in true }
        for entry in entries {
            switch entry.command {
            case .replaceAll, .replaceFrontmatter:
                Issue.record("argument-only command listed in the palette")
            default:
                break
            }
        }
    }

    @Test("A read-only context offers no palette commands")
    func readOnly() {
        let registry = MarkdownCommandRegistry()
        let context = MarkdownCommandContext(
            source: "text",
            selection: 0..<0,
            isReadOnly: true
        )
        let entries = MarkdownCommandCatalog.paletteEntries {
            registry.isAvailable($0, in: context)
        }
        #expect(entries.isEmpty)
    }

    @Test("A normal source context offers commands")
    func editable() {
        let registry = MarkdownCommandRegistry()
        let context = MarkdownCommandContext(
            source: "text",
            selection: 0..<0
        )
        let entries = MarkdownCommandCatalog.paletteEntries {
            registry.isAvailable($0, in: context)
        }
        #expect(entries.count > 10)
    }
}
