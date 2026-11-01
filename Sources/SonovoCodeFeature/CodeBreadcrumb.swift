import SwiftUI
import SonovoTextEngine
import SonovoDesignSystem

struct CodeSymbolMenu: View {
    let workspace: CodeWorkspace
    @State private var codeSymbols: [CodeSymbol] = []

    /// Loaded code documents commonly share revision 1. Key the symbol load
    /// by document identity and language, not revision alone.
    private struct SymbolTaskKey: Hashable {
        let documentID: UUID?
        let revision: UInt64
        let language: CodeLanguage?
        let isReady: Bool
    }

    var body: some View {
        Group { if let document = workspace.selectedDocument { symbolMenu(document) } }
            .task(id: symbolTaskKey) { await loadCodeSymbols() }
    }
    private var symbolTaskKey: SymbolTaskKey {
        let document = workspace.selectedDocument
        return SymbolTaskKey(
            documentID: document?.id,
            revision: document?.revision ?? 0,
            language: document?.language,
            isReady: document?.isReady ?? false
        )
    }

    private func symbolMenu(_ document: CodeDocument) -> some View {
        Menu {
            if codeSymbols.isEmpty {
                Text("No Symbols")
            } else {
                ForEach(codeSymbols) { symbol in
                    Button {
                        workspace.controller(for: document)
                            .goToLine(symbol.line)
                    } label: {
                        Text(
                            "\(symbol.kind.label)  \(symbol.name)"
                        )
                    }
                }
            }
        } label: {
            Image(systemName: "list.bullet.indent")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Go to Symbol")
        .accessibilityLabel("Go to Symbol")
    }

    private func loadCodeSymbols() async {
        guard let document = workspace.selectedDocument,
              document.language.supportsOutline,
              document.isReady else {
            codeSymbols = []
            return
        }
        let documentID = document.id
        let revision = document.revision
        let source = document.source
        let language = document.language
        let symbols = await Task.detached(priority: .utility) {
            CodeSymbolIndex.symbols(in: source, language: language)
        }.value
        // A stale task must not publish into another document's menu.
        guard !Task.isCancelled,
              workspace.selectedDocument?.id == documentID,
              document.revision == revision else { return }
        codeSymbols = symbols
    }

}
