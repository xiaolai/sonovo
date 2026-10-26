import AppKit
import SonovoCore
import SwiftUI

/// The result of one grid interaction. The editor owns the source; the grid
/// only renders the snapshot it was handed and asks for the next one.
enum MarkdownTableGridOutcome {
    case updated(MarkdownTableSnapshot)
    case refused(String)
}

@MainActor
final class MarkdownTablePopoverController {
    private let popover = NSPopover()

    func show(
        snapshot: MarkdownTableSnapshot,
        relativeTo rect: NSRect,
        of view: NSView,
        onSetCell: @escaping (Int, Int, String) -> MarkdownTableGridOutcome,
        onCommand: @escaping (
            MarkdownTableCommand,
            Int,
            Int
        ) -> MarkdownTableGridOutcome,
        onReload: @escaping () -> MarkdownTableGridOutcome,
        onClose: @escaping () -> Void
    ) {
        popover.behavior = .transient
        let root = MarkdownTableGridPopoverView(
            snapshot: snapshot,
            onSetCell: onSetCell,
            onCommand: onCommand,
            onReload: onReload,
            onClose: { [weak self] in
                onClose()
                self?.close()
            }
        )
        popover.contentViewController = NSHostingController(rootView: root)
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func close() {
        popover.performClose(nil)
    }
}

/// The grid editor. Each cell maps to one authored source cell; Return or
/// leaving the cell commits exactly that cell as one undoable edit. Empty
/// cells that a short row never authored stay visible but read-only.
struct MarkdownTableGridPopoverView: View {
    struct CellID: Hashable {
        let row: Int
        let column: Int
    }

    let onSetCell: (Int, Int, String) -> MarkdownTableGridOutcome
    let onCommand: (
        MarkdownTableCommand,
        Int,
        Int
    ) -> MarkdownTableGridOutcome
    let onReload: () -> MarkdownTableGridOutcome
    let onClose: () -> Void

    @State private var snapshot: MarkdownTableSnapshot
    @State private var drafts: [CellID: String] = [:]
    @State private var error: String?
    @FocusState private var focused: CellID?

    init(
        snapshot: MarkdownTableSnapshot,
        onSetCell: @escaping (Int, Int, String) -> MarkdownTableGridOutcome,
        onCommand: @escaping (
            MarkdownTableCommand,
            Int,
            Int
        ) -> MarkdownTableGridOutcome,
        onReload: @escaping () -> MarkdownTableGridOutcome,
        onClose: @escaping () -> Void
    ) {
        self._snapshot = State(initialValue: snapshot)
        self.onSetCell = onSetCell
        self.onCommand = onCommand
        self.onReload = onReload
        self.onClose = onClose
        var drafts: [CellID: String] = [:]
        for row in 0..<snapshot.rowCount {
            for column in 0..<snapshot.columnCount {
                drafts[CellID(row: row, column: column)] =
                    snapshot.content(row: row, column: column) ?? ""
            }
        }
        self._drafts = State(initialValue: drafts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            header
            if let error {
                errorBanner(error)
            }
            ScrollView([.horizontal, .vertical]) {
                grid
            }
            .background(AppTheme.MarkdownChrome.TableGrid.backdrop)
            .clipShape(
                RoundedRectangle(cornerRadius: AppTheme.Radius.micro)
            )
            alignmentRow
            Divider()
            structuralActions
        }
        .padding(AppTheme.Spacing.md)
        .frame(width: AppTheme.MarkdownChrome.TableGrid.width)
        .frame(height: AppTheme.MarkdownChrome.TableGrid.height)
        .background(AppTheme.MarkdownChrome.PaletteChrome.background)
        .onChange(of: focused) { previous, current in
            if let previous, previous != current {
                commit(previous)
            }
        }
        .onChange(of: snapshot) { _, _ in
            reloadDrafts()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table grid")
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Text("Table")
                .font(.system(size: AppTheme.TypeScale.sm, weight: .semibold))
            Text(
                "\(snapshot.rowCount) rows · \(snapshot.columnCount) columns"
            )
            .font(.system(size: AppTheme.TypeScale.xxs))
            .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(AppTheme.Palette.warning)
            Text(text)
                .font(.system(size: AppTheme.TypeScale.xxs))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: AppTheme.Spacing.zero)
            Button("Reload") { apply(onReload()) }
        }
        .padding(AppTheme.Spacing.xs)
        .background(AppTheme.Palette.warning.opacity(AppTheme.Opacity.faint))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.micro))
    }

    private var grid: some View {
        Grid(
            alignment: .leading,
            horizontalSpacing: AppTheme.Spacing.xxs,
            verticalSpacing: AppTheme.Spacing.xxs
        ) {
            ForEach(0..<snapshot.rowCount, id: \.self) { row in
                GridRow {
                    ForEach(0..<snapshot.columnCount, id: \.self) { column in
                        cell(row: row, column: column)
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.xs)
    }

    @ViewBuilder
    private func cell(row: Int, column: Int) -> some View {
        let id = CellID(row: row, column: column)
        if snapshot.cell(row: row, column: column) == nil {
            Text("—")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.tertiary)
                .frame(
                    width: AppTheme.MarkdownChrome.TableGrid.cellWidth
                )
                .frame(
                    minHeight: AppTheme.MarkdownChrome.TableGrid.cellMinHeight
                )
                .background(AppTheme.Palette.card.opacity(AppTheme.Opacity.ghostSoft))
                .accessibilityLabel(
                    "Row \(row + 1), column \(column + 1), not authored"
                )
        } else {
            TextField("", text: binding(id))
                .textFieldStyle(.plain)
                .font(
                    .system(
                        size: AppTheme.TypeScale.xs,
                        weight: row == 0 ? .semibold : .regular
                    )
                )
                .focused($focused, equals: id)
                .onSubmit { commit(id) }
                .lineLimit(1)
                .padding(.horizontal, AppTheme.Spacing.xs)
                .padding(.vertical, AppTheme.Spacing.xxs)
                .frame(
                    width: AppTheme.MarkdownChrome.TableGrid.cellWidth,
                    alignment: .leading
                )
                .frame(
                    minHeight: AppTheme.MarkdownChrome.TableGrid.cellMinHeight
                )
                .background(
                    row == 0
                        ? AppTheme.MarkdownChrome.TableGrid.headerBackground
                        : AppTheme.Palette.text
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.micro)
                        .stroke(
                            focused == id
                                ? AppTheme.Palette.selection
                                : AppTheme.Palette.separator,
                            lineWidth: AppTheme.BorderWidth.hairline
                        )
                }
                .accessibilityLabel(
                    row == 0
                        ? "Header column \(column + 1)"
                        : "Row \(row + 1), column \(column + 1)"
                )
        }
    }

    private var alignmentRow: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Text("Alignment")
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(.secondary)
            ForEach(0..<snapshot.columnCount, id: \.self) { column in
                Menu(alignmentLabel(column)) {
                    ForEach(
                        [
                            TableBlock.Alignment.none,
                            .left,
                            .center,
                            .right,
                        ],
                        id: \.self
                    ) { alignment in
                        Button(alignmentLabel(for: alignment)) {
                            runStructural(
                                .setAlignment(alignment),
                                row: 0,
                                column: column
                            )
                        }
                    }
                }
                .font(.system(size: AppTheme.TypeScale.xxs))
                .accessibilityLabel("Column \(column + 1) alignment")
            }
            Spacer()
        }
    }

    private var structuralActions: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Button("Add Row") {
                runStructural(.insertRowBelow)
            }
            Button("Add Column") {
                runStructural(.insertColumnRight)
            }
            Button("Delete Row") {
                runStructural(.deleteRow)
            }
            Button("Delete Column") {
                runStructural(.deleteColumn)
            }
            Spacer()
        }
        .font(.system(size: AppTheme.TypeScale.xs))
    }

    private var targetRow: Int {
        focused?.row ?? max(0, snapshot.rowCount - 1)
    }

    private var targetColumn: Int {
        focused?.column ?? max(0, snapshot.columnCount - 1)
    }

    private func binding(_ id: CellID) -> Binding<String> {
        Binding(
            get: {
                drafts[id]
                    ?? snapshot.content(row: id.row, column: id.column)
                    ?? ""
            },
            set: { drafts[id] = $0 }
        )
    }

    private func commit(_ id: CellID) {
        _ = commitDraft(id)
    }

    /// Commits one focused cell's draft. Returns false when the edit was
    /// refused, so a structural action can stop before acting on a snapshot
    /// that does not contain the text.
    @discardableResult
    private func commitDraft(_ id: CellID) -> Bool {
        guard let draft = drafts[id],
              draft != snapshot.content(row: id.row, column: id.column)
        else {
            return true
        }
        let outcome = onSetCell(id.row, id.column, draft)
        switch outcome {
        case let .updated(updated):
            snapshot = updated
            error = nil
            reloadDrafts()
            return true
        case let .refused(message):
            error = message
            return false
        }
    }

    /// Structural and alignment commands act on the saved table, so the
    /// focused cell's draft must be committed first; otherwise the command's
    /// reload would discard it.
    private func runStructural(
        _ command: MarkdownTableCommand,
        row: Int? = nil,
        column: Int? = nil
    ) {
        if let focused, !commitDraft(focused) { return }
        apply(onCommand(command, row ?? targetRow, column ?? targetColumn))
    }

    private func apply(_ outcome: MarkdownTableGridOutcome) {
        switch outcome {
        case let .updated(updated):
            snapshot = updated
            error = nil
            reloadDrafts()
        case let .refused(message):
            error = message
        }
    }

    private func reloadDrafts() {
        var updated: [CellID: String] = [:]
        for row in 0..<snapshot.rowCount {
            for column in 0..<snapshot.columnCount {
                updated[CellID(row: row, column: column)] =
                    snapshot.content(row: row, column: column) ?? ""
            }
        }
        drafts = updated
    }

    private func alignmentLabel(_ column: Int) -> String {
        alignmentLabel(for: snapshot.alignment(column: column)
            ?? TableBlock.Alignment.none)
    }

    private func alignmentLabel(
        for alignment: TableBlock.Alignment
    ) -> String {
        switch alignment {
        case .none: return "Default"
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        }
    }
}
