import SwiftUI

/// The diff surface: unified or side by side, with hunk navigation.
///
/// A diff row never relies on color alone: `+` and `−` are always drawn, and
/// VoiceOver reads the row's sign and line number.
struct CodeDiffView: View {
    let document: CodeDocument
    let pair: CodeDiffPair?
    let split: Bool
    let onCopyReference: () -> Void
    let onCopyDiff: () -> Void

    @State private var model: CodeDiffModel?
    @State private var currentHunk = 0
    @State private var isLoading = false

    private var unavailable: String? {
        if pair != nil {
            return nil
        }
        if case .unavailable(let reason) = document.availableDiff {
            return reason
        }
        return "Diff is unavailable for this document."
    }

    var body: some View {
        Group {
            if let unavailable {
                ContentUnavailableView(
                    "Diff Unavailable",
                    systemImage: "rectangle.split.2x1.slash",
                    description: Text(unavailable)
                )
            } else if isLoading || model == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let model {
                diffContent(model)
            }
        }
        .task(id: pair) {
            guard let pair else {
                model = nil
                return
            }
            isLoading = true
            let worker = Task.detached(priority: .userInitiated) {
                CodeDiffModel.compare(pair)
            }
            let computed = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            model = computed
            currentHunk = 0
            isLoading = false
        }
    }

    private func diffContent(_ model: CodeDiffModel) -> some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            hunkBar(model)
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: AppTheme.Spacing.zero) {
                        if model.hasChanges {
                            ForEach(model.hunks) { hunk in
                                hunkHeader(hunk)
                                    .id(hunk.id)
                                if split {
                                    ForEach(
                                        Array(sideBySide(hunk.rows).enumerated()),
                                        id: \.offset
                                    ) { _, row in
                                        sideBySideRow(row)
                                    }
                                } else {
                                    ForEach(hunk.rows) { row in
                                        unifiedRow(row)
                                    }
                                }
                            }
                        } else {
                            Text("No changes.")
                                .font(.system(size: AppTheme.TypeScale.sm))
                                .foregroundStyle(.secondary)
                                .padding(AppTheme.Spacing.lg)
                        }
                    }
                }
                .onChange(of: currentHunk) { _, index in
                    guard model.hunks.indices.contains(index) else {
                        return
                    }
                    withAnimation(AppTheme.Motion.panel) {
                        proxy.scrollTo(model.hunks[index].id, anchor: .top)
                    }
                }
            }
        }
    }

    private func hunkBar(_ model: CodeDiffModel) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(model.leftLabel)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
            Text(model.rightLabel)
                .foregroundStyle(.secondary)
            Text("\(model.leftLineCount) → \(model.rightLineCount) lines")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer()
            Text("+\(model.addedCount) −\(model.removedCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if !model.hunks.isEmpty {
                Button {
                    currentHunk = max(0, currentHunk - 1)
                } label: {
                    Label("Previous Change", systemImage: "chevron.up")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .disabled(currentHunk == 0)
                .help("Previous Change")
                .accessibilityLabel("Previous Change")

                Text("\(currentHunk + 1) / \(model.hunks.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Button {
                    currentHunk = min(
                        model.hunks.count - 1,
                        currentHunk + 1
                    )
                } label: {
                    Label("Next Change", systemImage: "chevron.down")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .disabled(currentHunk >= model.hunks.count - 1)
                .help("Next Change")
                .accessibilityLabel("Next Change")
            }
            Button("Copy Diff", action: onCopyDiff)
            Button("Copy Reference", action: onCopyReference)
        }
        .font(.system(size: AppTheme.TypeScale.xs))
        .padding(.horizontal, AppTheme.Spacing.sm)
        .frame(height: AppTheme.Code.toolbarHeight)
    }

    private func hunkHeader(_ hunk: CodeDiffHunk) -> some View {
        Text(hunk.header)
            .font(
                .system(
                    size: AppTheme.TypeScale.xs,
                    design: .monospaced
                )
            )
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(Color.appCard)
            .accessibilityLabel(hunk.header)
    }

    private func unifiedRow(_ row: CodeDiffRow) -> some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            lineNumber(row.left?.number)
            lineNumber(row.right?.number)
            Text(sign(for: row.kind))
                .foregroundStyle(signColor(for: row.kind))
                .frame(
                    width: AppTheme.Code.diffGutterWidth,
                    alignment: .leading
                )
            Text(rowText(for: row))
                .font(
                    .system(
                        size: AppTheme.Code.fontSize,
                        design: .monospaced
                    )
                )
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isNoNewline(row) {
                Text("no newline")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .frame(
            height: AppTheme.Code.searchResultRowHeight,
            alignment: .leading
        )
        .background(rowBackground(for: row.kind))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: row))
    }

    private func sideBySideRow(_ row: SideRow) -> some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            sideCell(row.left, isLeft: true)
            Divider()
            sideCell(row.right, isLeft: false)
        }
        .frame(
            height: AppTheme.Code.searchResultRowHeight,
            alignment: .leading
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sideAccessibilityLabel(for: row))
    }

    private func sideCell(_ row: CodeDiffRow?, isLeft: Bool) -> some View {
        let line = isLeft ? row?.left : row?.right
        let kind: CodeDiffRow.Kind
        if row?.kind == .equal || line == nil {
            kind = .equal
        } else {
            kind = isLeft ? .delete : .insert
        }
        return HStack(spacing: AppTheme.Spacing.xxs) {
            lineNumber(line?.number)
            Text(sign(for: kind))
                .foregroundStyle(signColor(for: kind))
                .frame(
                    width: AppTheme.Code.diffGutterWidth,
                    alignment: .leading
                )
            Text(line?.text ?? "")
                .font(
                    .system(
                        size: AppTheme.Code.fontSize,
                        design: .monospaced
                    )
                )
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
            if line?.terminator == CodeLineTerminator.none {
                Text("no newline")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.tertiary)
            }
        }
        .background(rowBackground(for: kind))
    }

    private func lineNumber(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(
                .system(
                    size: AppTheme.Code.lineNumberFontSize,
                    design: .monospaced
                )
            )
            .foregroundStyle(.tertiary)
            .frame(
                width: AppTheme.Code.diffLineNumberWidth,
                alignment: .trailing
            )
    }

    private func sign(for kind: CodeDiffRow.Kind) -> String {
        switch kind {
        case .equal: " "
        case .delete: "−"
        case .insert: "+"
        }
    }

    private func signColor(for kind: CodeDiffRow.Kind) -> Color {
        switch kind {
        case .equal: .clear
        case .delete: .appSyntaxDeleted
        case .insert: .appSyntaxInserted
        }
    }

    private func rowBackground(for kind: CodeDiffRow.Kind) -> Color {
        switch kind {
        case .equal: .clear
        case .delete: .appSyntaxDeleted
            .opacity(AppTheme.Code.diffRemovedOpacity)
        case .insert: .appSyntaxInserted
            .opacity(AppTheme.Code.diffAddedOpacity)
        }
    }

    private func rowText(for row: CodeDiffRow) -> String {
        row.left?.text ?? row.right?.text ?? ""
    }

    private func isNoNewline(_ row: CodeDiffRow) -> Bool {
        if row.kind == .delete {
            return row.left?.terminator == CodeLineTerminator.none
        }
        if row.kind == .insert {
            return row.right?.terminator == CodeLineTerminator.none
        }
        return row.left?.terminator == CodeLineTerminator.none
            || row.right?.terminator == CodeLineTerminator.none
    }

    private func accessibilityLabel(for row: CodeDiffRow) -> String {
        switch row.kind {
        case .equal:
            return "Unchanged line \(row.left?.number ?? 0): "
                + (row.left?.text ?? "")
        case .delete:
            return "Removed line \(row.left?.number ?? 0): "
                + (row.left?.text ?? "")
        case .insert:
            return "Added line \(row.right?.number ?? 0): "
                + (row.right?.text ?? "")
        }
    }

    private func sideAccessibilityLabel(for row: SideRow) -> String {
        let left = row.left.map { describe($0, side: .delete, isLeft: true) }
            ?? "left blank"
        let right = row.right.map { describe($0, side: .insert, isLeft: false) }
            ?? "right blank"
        return "\(left), \(right)"
    }

    private func describe(
        _ row: CodeDiffRow,
        side: CodeDiffRow.Kind,
        isLeft: Bool
    ) -> String {
        let line = isLeft ? row.left : row.right
        let kind: String
        if row.kind == .equal {
            kind = "unchanged"
        } else {
            kind = side == .delete ? "removed" : "added"
        }
        let noNewline = line?.terminator == CodeLineTerminator.none
            ? ", no final newline"
            : ""
        return "\(isLeft ? "left" : "right") \(kind) line "
            + "\(line?.number ?? 0): \(line?.text ?? "")\(noNewline)"
    }

    // MARK: - Side-by-side pairing

    private struct SideRow {
        let left: CodeDiffRow?
        let right: CodeDiffRow?
    }

    private func sideBySide(_ rows: [CodeDiffRow]) -> [SideRow] {
        var result: [SideRow] = []
        var index = 0
        while index < rows.count {
            let row = rows[index]
            if row.kind == .equal {
                result.append(SideRow(left: row, right: row))
                index += 1
                continue
            }
            var deletes: [CodeDiffRow] = []
            var inserts: [CodeDiffRow] = []
            while index < rows.count, rows[index].kind != .equal {
                if rows[index].kind == .delete {
                    deletes.append(rows[index])
                } else {
                    inserts.append(rows[index])
                }
                index += 1
            }
            let count = max(deletes.count, inserts.count)
            for offset in 0..<count {
                result.append(
                    SideRow(
                        left: offset < deletes.count ? deletes[offset] : nil,
                        right: offset < inserts.count ? inserts[offset] : nil
                    )
                )
            }
        }
        return result
    }
}
