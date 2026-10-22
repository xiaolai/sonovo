import AppKit
import Foundation
import Observation
import PDFKit
import SwiftUI

@MainActor
@Observable
final class PDFDocumentModel {
    enum State: Equatable, Sendable {
        case idle
        case loading
        case locked
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var document: PDFDocument?
    private(set) var pageCount = 0
    private(set) var searchResults: [PDFSelection] = []
    private(set) var searchIndex = 0
    let url: URL
    private var findObservers: [NSObjectProtocol] = []
    private var pendingResults: [PDFSelection] = []
    private var searchContinuation: CheckedContinuation<Int, Never>?
    /// Identifies the current find. A cancelled search's deferred handler
    /// must not cancel a newer search that already started.
    private var searchGeneration: UInt64 = 0

    init(url: URL) {
        self.url = url
    }

    isolated deinit {
        removeFindObservers()
    }

    var currentSelection: PDFSelection? {
        guard !searchResults.isEmpty,
              searchResults.indices.contains(searchIndex) else {
            return nil
        }
        return searchResults[searchIndex]
    }

    /// Identifies the current load. A cancelled or superseded parse must not
    /// publish after a newer one has started.
    private var loadGeneration: UInt64 = 0

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        state = .loading
        // A search belongs to the document being replaced. Resolve its
        // waiter and clear the results before the new PDF takes over, or the
        // old selections stay attached to a document nobody displays.
        resetSearch()
        let url = self.url
        // Parse off the main actor. The document is created and handed back
        // through an explicit unchecked wrapper; it is used only on the
        // main actor after this point.
        let loaded = await Task.detached(priority: .userInitiated) {
            LoadedPDF(document: PDFDocument(url: url))
        }.value
        // A newer load owns the state now; discard this result.
        guard generation == loadGeneration else { return }
        // The viewer can disappear while the parse runs. Its onDisappear
        // removed the observers this load would reinstall; publishing now
        // would leave a document on a dismantled view.
        guard !Task.isCancelled else {
            state = .idle
            return
        }
        guard let document = loaded.document else {
            state = .failed("This PDF could not be opened.")
            return
        }
        // A search may have started against the retained old document while
        // this parse was suspended. It belongs to the document being
        // replaced, so its observers and waiter must not survive adoption.
        resetSearch()
        self.document = document
        pageCount = document.pageCount
        state = document.isLocked ? .locked : .ready
        installFindObservers(for: document)
    }

    @discardableResult
    func unlock(password: String) -> Bool {
        guard let document else { return false }
        guard document.unlock(withPassword: password) else {
            state = .locked
            return false
        }
        pageCount = document.pageCount
        state = .ready
        return true
    }

    /// Finds text with PDFKit's asynchronous API. The synchronous
    /// `findString` blocks the main actor for the whole document.
    @discardableResult
    func search(_ query: String) async -> Int {
        let trimmed = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        searchGeneration &+= 1
        let generation = searchGeneration
        searchResults = []
        searchIndex = 0
        pendingResults = []
        if let continuation = searchContinuation {
            searchContinuation = nil
            continuation.resume(returning: 0)
        }
        // Stop any previous find even when the new query is empty; otherwise
        // its late matches can reappear after the results were cleared.
        removeFindObservers()
        document?.cancelFindString()
        guard let document, !trimmed.isEmpty else { return 0 }

        installFindObservers(for: document)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                searchContinuation = continuation
                document.beginFindString(
                    trimmed,
                    withOptions: [.caseInsensitive]
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelSearch(generation: generation)
            }
        }
    }

    /// Stops PDFKit's find and resolves the waiting caller. Called when the
    /// viewer disappears or its search task is cancelled.
    func cancelSearch() {
        searchGeneration &+= 1
        cancelFind()
    }

    /// A stale cancellation (the previous find's task) is ignored once a
    /// newer search has begun.
    private func cancelSearch(generation: UInt64) {
        guard generation == searchGeneration else { return }
        cancelFind()
    }

    private func cancelFind() {
        removeFindObservers()
        document?.cancelFindString()
        if let continuation = searchContinuation {
            searchContinuation = nil
            continuation.resume(returning: 0)
        }
    }

    /// Invalidates any in-flight search and clears its results, so nothing
    /// from the old document can be published.
    private func resetSearch() {
        searchGeneration &+= 1
        cancelFind()
        searchResults = []
        searchIndex = 0
        pendingResults = []
    }

    private func installFindObservers(for document: PDFDocument) {
        let center = NotificationCenter.default
        findObservers.append(
            center.addObserver(
                forName: .PDFDocumentDidFindMatch,
                object: document,
                queue: .main
            ) { [weak self] note in
                guard let selection = note.userInfo?[
                    PDFDocumentFoundSelectionKey
                ] as? PDFSelection else { return }
                // The observer is registered for this document only, so the
                // selection cannot come from a replaced document. The box is
                // the explicit transfer of a non-Sendable PDFKit value onto
                // the main actor, where every other use of it lives.
                let box = PDFSelectionBox(selection: selection)
                MainActor.assumeIsolated {
                    self?.pendingResults.append(box.selection)
                }
            }
        )
        findObservers.append(
            center.addObserver(
                forName: .PDFDocumentDidEndFind,
                object: document,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.searchResults = self.pendingResults
                    self.searchIndex = 0
                    let continuation = self.searchContinuation
                    self.searchContinuation = nil
                    continuation?.resume(
                        returning: self.searchResults.count
                    )
                }
            }
        )
    }

    private func removeFindObservers() {
        for observer in findObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        findObservers.removeAll()
    }

    func nextSearchResult() {
        guard !searchResults.isEmpty else { return }
        searchIndex = (searchIndex + 1) % searchResults.count
    }

    var fileSize: Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))
            .flatMap(\.fileSize).map(Int64.init) ?? 0
    }
}

private struct LoadedPDF: @unchecked Sendable {
    let document: PDFDocument?
}

private struct PDFSelectionBox: @unchecked Sendable {
    let selection: PDFSelection
}

@MainActor
struct PDFDocumentView: View {
    let asset: ProjectAsset

    @State private var model: PDFDocumentModel
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var password = ""

    init(asset: ProjectAsset) {
        self.asset = asset
        _model = State(initialValue: PDFDocumentModel(url: asset.url))
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            header
            Divider()
            content
        }
        .viewerCard()
        .task {
            // Always start a load. Reappearing while an earlier parse is
            // still running starts a newer generation; the older parse then
            // discards its result instead of leaving `.idle` behind.
            await model.load()
        }
        .onDisappear {
            searchTask?.cancel()
            model.cancelSearch()
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "doc.richtext")
                .font(.system(size: AppTheme.TypeScale.body))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(asset.name)
                    .font(.system(size: AppTheme.TypeScale.md, weight: .semibold))
                    .lineLimit(1)
                Text(
                    model.pageCount == 0
                        ? asset.fileExtension.uppercased()
                        : "\(model.pageCount) pages · \(sizeLabel)"
                )
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: AppTheme.Layout.documentSearchFieldWidth)
                .onSubmit {
                    searchTask?.cancel()
                    searchTask = Task { await model.search(query) }
                }
                .disabled(model.state != .ready)

            if !model.searchResults.isEmpty {
                Text("\(model.searchIndex + 1)/\(model.searchResults.count)")
                    .font(.system(size: AppTheme.TypeScale.xxs, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Button("Next") {
                    model.nextSearchResult()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: AppTheme.Layout.subtitleHeaderHeight)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView("Loading PDF…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .locked:
            lockedState
        case .failed(let message):
            failureState(message)
        case .ready:
            if let document = model.document {
                PDFKitView(
                    document: document,
                    selection: model.currentSelection
                )
            }
        }
    }

    private var lockedState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "lock.doc")
                .font(
                    .system(
                        size: AppTheme.TypeScale.displayLarge,
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(.tertiary)
            Text("This PDF is password protected")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: AppTheme.Layout.emptyDescriptionMaxWidth)
                .onSubmit { attemptUnlock() }
            Button("Unlock") {
                attemptUnlock()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func attemptUnlock() {
        _ = model.unlock(password: password)
        password = ""
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "doc.badge.exclamationmark")
                .font(
                    .system(
                        size: AppTheme.TypeScale.displayLarge,
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(AppTheme.Palette.warning)
            Text("Could not open this PDF")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))
            Text(message)
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
            Button("Open in Default App") {
                NSWorkspace.shared.open(asset.url)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sizeLabel: String {
        ByteCountFormatter.string(
            fromByteCount: model.fileSize,
            countStyle: .file
        )
    }
}

private struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    let selection: PDFSelection?

    final class Coordinator {
        var lastSelection: PDFSelection?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
            context.coordinator.lastSelection = nil
        }
        if let selection {
            guard context.coordinator.lastSelection !== selection else {
                return
            }
            // `go(to:)` scrolls but does not select; set the selection so
            // the match is highlighted and the next comparison is stable.
            view.setCurrentSelection(selection, animate: false)
            view.go(to: selection)
            context.coordinator.lastSelection = selection
        } else if context.coordinator.lastSelection != nil {
            view.setCurrentSelection(nil, animate: false)
            context.coordinator.lastSelection = nil
        }
    }
}
