import SwiftUI

struct EditorBreadcrumb: View {
    let state: AppState
    let project: Project

    @State private var codeSymbols: [CodeSymbol] = []

    /// Loaded code documents commonly share revision 1. Key the symbol load
    /// by document identity and language, not revision alone.
    private struct SymbolTaskKey: Hashable {
        let documentID: UUID?
        let revision: UInt64
        let language: CodeLanguage?
        let isReady: Bool
        let tabKind: AssetKind?
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            if let content {
                Image(systemName: content.icon)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)

                Text(content.rootTitle)
                    .lineLimit(1)

                chevron
                Text(content.groupTitle)
                    .lineLimit(1)
                chevron
                Text(content.name)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if project.selectedTab?.kind == .code,
                   let document = project.code.selectedDocument {
                    symbolMenu(document)
                }

                Spacer(minLength: AppTheme.Spacing.sm)

                Text(content.detail)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text("No Editor")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.system(size: AppTheme.TypeScale.xs))
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: AppTheme.Layout.breadcrumbHeight)
        .background(Color.appWindow)
        .task(id: symbolTaskKey) {
            await loadCodeSymbols()
        }
    }

    private var symbolTaskKey: SymbolTaskKey {
        let document = project.code.selectedDocument
        return SymbolTaskKey(
            documentID: document?.id,
            revision: document?.revision ?? 0,
            language: document?.language,
            isReady: document?.isReady ?? false,
            tabKind: project.selectedTab?.kind
        )
    }

    private func symbolMenu(_ document: CodeDocument) -> some View {
        Menu {
            if codeSymbols.isEmpty {
                Text("No Symbols")
            } else {
                ForEach(codeSymbols) { symbol in
                    Button {
                        project.code.controller(for: document)
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
        guard project.selectedTab?.kind == .code,
              let document = project.code.selectedDocument,
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
              project.selectedTab?.kind == .code,
              project.code.selectedDocument?.id == documentID,
              document.revision == revision else { return }
        codeSymbols = symbols
    }

    /// The breadcrumb trail for the selected asset, workspace document, or
    /// sample asset. Resolving it before the layout keeps one rendering path.
    private var content: BreadcrumbContent? {
        if !project.isDemo, let asset = project.selectedAsset {
            return BreadcrumbContent(
                icon: asset.kind.icon,
                rootTitle: project.name,
                groupTitle: asset.kind.projectGroup.title,
                name: asset.name,
                detail: codeDetail(for: asset) ?? asset.detail
            )
        }
        if !project.isDemo,
           let kind = project.selectedTab?.workspaceKind,
           let identity = project.workspaceDocumentIdentity(for: kind) {
            return BreadcrumbContent(
                icon: kind.icon,
                rootTitle: project.name,
                groupTitle: kind.projectGroup.title,
                name: identity.name,
                detail: identity.detail
            )
        }
        if project.isDemo,
           let tab = project.selectedTab,
           let asset = state.production.asset(id: tab.assetID) {
            return BreadcrumbContent(
                icon: tab.kind.icon,
                rootTitle: state.production.title,
                groupTitle: state.production.stage(for: asset.id)?.title
                    ?? "Production",
                name: state.displayName(for: asset),
                detail: asset.detail
            )
        }
        return nil
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: AppTheme.TypeScale.tiny, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    /// `path › file › symbol` for code: the language, the nearest symbol, and
    /// the caret position, from the same retained controller the editor uses.
    private func codeDetail(for asset: ProjectAsset) -> String? {
        guard asset.kind == .code,
              let document = project.code.selectedDocument,
              document.fileURL.standardizedFileURL
                == asset.url.standardizedFileURL else {
            return nil
        }
        let controller = project.code.editorCache.cachedController(
            for: document.id
        )
        var parts = [document.language.displayName]
        if let symbol = controller?.symbolName {
            parts.append(symbol)
        }
        if let controller {
            parts.append("L\(controller.cursorLine):\(controller.cursorColumn)")
        }
        return parts.joined(separator: " · ")
    }
}

private struct BreadcrumbContent {
    let icon: String
    let rootTitle: String
    let groupTitle: String
    let name: String
    let detail: String
}
