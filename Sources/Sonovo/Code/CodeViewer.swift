import AppKit
import SwiftUI

// MARK: - Reference delivery

enum CodeReferenceOutcome: Equatable {
    case sent
    case copied
    case rejected
}

/// Delivers a one-line code reference.
///
/// The terminal receives only sanitized text: C0/C1 controls and newlines are
/// stripped, and Enter is never appended. A multiline selection goes to the
/// clipboard instead. When the terminal sink refuses (hidden, gone, or owned
/// by another project), the reference is copied and the user is told.
struct CodeReferenceDelivery {
    var send: ((String) -> Bool)?
    var copy: (String) -> Void

    static func sanitized(_ text: String) -> String? {
        let filtered = text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let result = String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }

    func deliver(reference: String, multiline: Bool) -> CodeReferenceOutcome {
        if multiline {
            copy(reference)
            return .copied
        }
        guard let clean = Self.sanitized(reference) else {
            return .rejected
        }
        if let send, send(clean) {
            return .sent
        }
        copy(clean)
        return .copied
    }
}

// MARK: - Workspace view

struct CodeWorkspaceView: View {
    let workspace: CodeWorkspace
    let project: Project

    @State private var showReviewQueue = false

    var body: some View {
        Group {
            if let document = workspace.selectedDocument {
                CodeViewer(
                    document: document,
                    workspace: workspace,
                    project: project
                )
                .id(document.id)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appCanvas)
        .sheet(isPresented: $showReviewQueue) {
            CodeReviewQueueSheet(workspace: workspace)
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(
                    .system(
                        size: AppTheme.TypeScale.displayLarge,
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(.tertiary)
            Text("No Code File")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))
            Text("Open a code file from the project navigator.")
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Open…") { workspace.presentOpenPanel() }
                Button("Project Changes…") { showReviewQueue = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - One document

struct CodeViewer: View {
    @Bindable var document: CodeDocument
    let workspace: CodeWorkspace
    let project: Project

    @State private var showGoToLine = false
    @State private var showSymbols = false
    @State private var showSearch = false
    @State private var showReview = false
    @State private var showReviewQueue = false
    @State private var reviewDisposition: CodeReviewDisposition = .seen
    @State private var reviewNote = ""
    @State private var reviewPair: CodeDiffPair?
    @State private var reviewPath = ""
    @State private var reviewReference = ""
    @State private var reviewMessage: String?
    @State private var goToLineText = ""
    @State private var referenceMessage: String?
    @State private var symbols: [CodeSymbol] = []
    @State private var symbolTask: Task<Void, Never>?
    @AppStorage("sonovo.codeTabWidth")
    private var codeTabWidth = AppTheme.Code.tabWidthDefault
    @AppStorage("sonovo.codeUsesTabs") private var codeUsesTabs = false
    @AppStorage("sonovo.codeWrapLines") private var codeWrapLines = false

    private var editorSettings: CodeEditorSettings {
        CodeEditorSettings(
            tabWidth: codeTabWidth,
            usesTabs: codeUsesTabs,
            wrapsLines: codeWrapLines
        )
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            toolbar
            Divider()

            if let error = workspace.lastError {
                banner(
                    text: error,
                    systemImage: "exclamationmark.triangle",
                    tint: AppTheme.Palette.warning,
                    dismiss: workspace.dismissError
                )
            }

            if let error = workspace.controller(for: document)
                .lastCommandError {
                banner(
                    text: "\(error)",
                    systemImage: "exclamationmark.triangle",
                    tint: AppTheme.Palette.warning,
                    dismiss: {
                        workspace.controller(for: document)
                            .dismissCommandError()
                    }
                )
            }

            if let notice = workspace.notice(for: document) {
                noticeBanner(notice)
            }

            if let conflict = document.conflict {
                conflictBanner(conflict)
            }

            if let reason = document.readOnlyReason,
               document.refusal == nil {
                readOnlyBanner(reason)
            }

            if document.isMissingOnDisk {
                banner(
                    text: "This file is missing on disk.",
                    systemImage: "questionmark.folder",
                    tint: AppTheme.Palette.warning
                )
            }

            documentContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusBar
            Divider()
        }
        .background(Color.appText)
        .alert(
            "Replace “\(workspace.pendingOverwrite?.url.lastPathComponent ?? "file")”?",
            isPresented: Binding(
                get: {
                    workspace.pendingOverwrite?.id == document.id
                },
                set: { presented in
                    if !presented { workspace.cancelOverwrite() }
                }
            )
        ) {
            Button("Replace", role: .destructive) {
                guard let request = workspace.pendingOverwrite else {
                    return
                }
                Task { await workspace.confirmOverwrite(request) }
            }
            Button("Cancel", role: .cancel) {
                workspace.cancelOverwrite()
            }
        } message: {
            Text("A file already exists at that path.")
        }
        .alert(
            "Reference",
            isPresented: Binding(
                get: { referenceMessage != nil },
                set: { presented in
                    if !presented { referenceMessage = nil }
                }
            )
        ) {
            Button("OK") { referenceMessage = nil }
        } message: {
            Text(referenceMessage ?? "")
        }
        .sheet(isPresented: $showGoToLine) {
            goToLineSheet
        }
        .sheet(isPresented: $showSymbols) {
            symbolSheet
        }
        .sheet(isPresented: $showSearch) {
            CodeSearchSheet(workspace: workspace, project: project)
        }
        .sheet(isPresented: $showReview) {
            reviewSheet
        }
        .sheet(isPresented: $showReviewQueue) {
            CodeReviewQueueSheet(workspace: workspace)
        }
        .task {
            workspace.controller(for: document)
                .updateSettings(editorSettings)
            loadSymbols()
        }
        .onChange(of: codeTabWidth) { _, _ in
            workspace.controller(for: document)
                .updateSettings(editorSettings)
        }
        .onChange(of: codeUsesTabs) { _, _ in
            workspace.controller(for: document)
                .updateSettings(editorSettings)
        }
        .onChange(of: codeWrapLines) { _, _ in
            workspace.controller(for: document)
                .updateSettings(editorSettings)
        }
        .onChange(of: document.revision) { _, _ in
            loadSymbols()
        }
        .onChange(of: document.language) { _, _ in
            // Save As can change the language without changing the revision.
            loadSymbols()
        }
        .onDisappear {
            symbolTask?.cancel()
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            documentMenu
            undoRedo
            Divider().frame(height: AppTheme.Size.toolbarDividerHeight)
            modePicker

            Spacer(minLength: AppTheme.Spacing.sm)

            Button {
                workspace.controller(for: document).showFindBar()
            } label: {
                toolbarIcon("magnifyingglass")
            }
            .buttonStyle(.plain)
            .help("Find")
            .accessibilityLabel("Find")

            Button {
                goToLineText = "\(workspace.controller(for: document).cursorLine)"
                showGoToLine = true
            } label: {
                toolbarIcon("arrow.right.to.line")
            }
            .buttonStyle(.plain)
            .help("Go to Line")
            .accessibilityLabel("Go to Line")

            Button {
                showSymbols = true
            } label: {
                toolbarIcon("list.bullet.indent")
            }
            .buttonStyle(.plain)
            .disabled(!document.language.supportsOutline)
            .help("Go to Symbol")
            .accessibilityLabel("Go to Symbol")

            Button {
                showSearch = true
            } label: {
                toolbarIcon("text.magnifyingglass")
            }
            .buttonStyle(.plain)
            .help("Search Project")
            .accessibilityLabel("Search Project")

            Button {
                showReviewQueue = true
            } label: {
                toolbarIcon("clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            .help("Project Changes")
            .accessibilityLabel("Project Changes")

            Divider().frame(height: AppTheme.Size.toolbarDividerHeight)

            referenceMenu

            if document.isDirty, document.conflict == nil {
                Button {
                    Task { await workspace.revertToDisk(document) }
                } label: {
                    toolbarIcon("arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .help("Revert File to Disk")
                .accessibilityLabel("Revert File to Disk")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .frame(height: AppTheme.Code.toolbarHeight)
    }

    private var documentMenu: some View {
        Menu {
            Section("Open Code Documents") {
                ForEach(workspace.documents) { candidate in
                    Button(candidate.displayName) {
                        workspace.select(candidate)
                    }
                }
            }
            Divider()
            Button("Open…") { workspace.presentOpenPanel() }
            Button("Save") {
                Task { await workspace.save(document) }
            }
            .disabled(!document.isDirty || !document.canAttemptSave)
            Button("Save As…") {
                Task { await workspace.saveAs(document) }
            }
            Divider()
            Button("Copy Path") {
                copyToPasteboard(document.fileURL.path)
            }
            Button("Open in Default App") {
                workspace.openInDefaultApplication(document.fileURL)
            }
            Divider()
            Button("Close") {
                if let tab = project.openTabs.first(where: {
                    $0.kind == .code
                        && $0.url?.standardizedFileURL
                        == document.fileURL.standardizedFileURL
                }) {
                    Task { await project.closeTab(tab.id) }
                }
            }
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
                .frame(
                    width: AppTheme.ControlSize.medium,
                    height: AppTheme.ControlSize.regular
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Code Documents")
        .accessibilityLabel("Code Documents")
    }

    private var undoRedo: some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            Button {
                document.undoManager.undo()
            } label: {
                toolbarIcon("arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .disabled(!document.undoManager.canUndo)
            .help("Undo")
            .accessibilityLabel("Undo")

            Button {
                document.undoManager.redo()
            } label: {
                toolbarIcon("arrow.uturn.forward")
            }
            .buttonStyle(.plain)
            .disabled(!document.undoManager.canRedo)
            .help("Redo")
            .accessibilityLabel("Redo")
        }
    }

    private var modePicker: some View {
        Picker(
            "View",
            selection: Binding(
                get: { document.viewMode },
                set: { mode in
                    if mode.isDiff {
                        // Switching layouts must not recapture an existing
                        // A→C pair as C→C.
                        if !document.isDirty,
                           document.reviewedDiff == nil {
                            workspace.captureReviewDiff(document)
                        }
                    } else {
                        document.clearReviewedDiff()
                    }
                    document.viewMode = mode
                }
            )
        ) {
            ForEach(CodeViewMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Source or Diff")
        .accessibilityLabel("Source or Diff")
    }

    private var referenceMenu: some View {
        Menu {
            Button("Copy Reference") {
                deliverReference(copyOnly: true)
            }
            Button("Send Reference to Terminal") {
                deliverReference(copyOnly: false)
            }
            Button("Copy Diff") {
                copyDiff()
            }
            .disabled(document.viewMode == .source)
        } label: {
            toolbarIcon("number")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Reference")
        .accessibilityLabel("Reference")
    }

    private func toolbarIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
            .frame(
                width: AppTheme.ControlSize.medium,
                height: AppTheme.ControlSize.regular
            )
            .contentShape(Rectangle())
    }

    // MARK: Content

    @ViewBuilder
    private var documentContent: some View {
        if let refusal = document.refusal {
            refusalCard(refusal)
        } else if document.viewMode.isDiff {
            VStack(spacing: AppTheme.Spacing.zero) {
                reviewBar
                Divider()
                CodeDiffView(
                    document: document,
                    pair: diffPair,
                    split: document.viewMode == .splitDiff,
                    onCopyReference: {
                        deliverReference(copyOnly: true)
                    },
                    onCopyDiff: copyDiff
                )
            }
        } else {
            CodeSourceView(document: document, workspace: workspace)
        }
    }

    private var diffPair: CodeDiffPair? {
        if let reviewed = document.reviewedDiff {
            return reviewed
        }
        if case .available(let pair) = document.availableDiff {
            return pair
        }
        return nil
    }

    // MARK: Review

    private var reviewBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if let decision = document.reviewDecision {
                Image(
                    systemName: decision.disposition == .seen
                        ? "eye"
                        : "exclamationmark.bubble"
                )
                .font(.system(size: AppTheme.TypeScale.xs, weight: .medium))
                .foregroundStyle(
                    decision.disposition == .seen
                        ? Color.secondary
                        : Color(AppTheme.Palette.warning)
                )
                Text(decision.disposition.label)
                    .font(
                        .system(
                            size: AppTheme.TypeScale.xs,
                            weight: .medium
                        )
                    )
                Text(decision.pairSummary)
                    .font(
                        .system(
                            size: AppTheme.TypeScale.xs,
                            design: .monospaced
                        )
                    )
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if document.reviewDecisionIsStale {
                    Text("Stale")
                        .font(
                            .system(
                                size: AppTheme.TypeScale.xs,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(Color(AppTheme.Palette.warning))
                        .help("The pair changed since this decision.")
                }
                Spacer(minLength: AppTheme.Spacing.sm)
                Button("Instruction…") { presentReview() }
                Button("Clear") {
                    Task {
                        await workspace.clearReviewDecision(in: document)
                    }
                }
            } else {
                Text("No review decision for this pair.")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
                Spacer(minLength: AppTheme.Spacing.sm)
                Button("Review…") { presentReview() }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(Color.appCard)
    }

    private var reviewSheet: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Review This Change")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .semibold))

            if let pair = reviewPair {
                Text(document.relativePath(relativeTo: project.root))
                    .font(
                        .system(
                            size: AppTheme.TypeScale.sm,
                            design: .monospaced
                        )
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(pairSummary(pair))
                    .font(
                        .system(
                            size: AppTheme.TypeScale.xs,
                            design: .monospaced
                        )
                    )
                    .foregroundStyle(.secondary)
            } else {
                Text("This diff cannot be reviewed at its current size.")
                    .font(.system(size: AppTheme.TypeScale.sm))
                    .foregroundStyle(.secondary)
            }
            if let message = reviewMessage {
                Text(message)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(Color(AppTheme.Palette.warning))
            }

            Picker("Decision", selection: $reviewDisposition) {
                ForEach(CodeReviewDisposition.allCases) { disposition in
                    Text(disposition.label).tag(disposition)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("Note for the worker")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
            TextEditor(text: $reviewNote)
                .font(
                    .system(
                        size: AppTheme.TypeScale.sm,
                        design: .monospaced
                    )
                )
                .frame(height: AppTheme.Code.reviewNoteHeight)
                .overlay(
                    RoundedRectangle(
                        cornerRadius: AppTheme.Radius.control
                    )
                    .strokeBorder(
                        Color.appSeparator,
                        lineWidth: AppTheme.BorderWidth.hairline
                    )
                )

            if let decision = draftDecision {
                Text("Instruction")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(CodeReviewInstruction.text(for: decision))
                        .font(
                            .system(
                                size: AppTheme.TypeScale.xs,
                                design: .monospaced
                            )
                        )
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppTheme.Spacing.sm)
                }
                .frame(height: AppTheme.Code.reviewNoteHeight)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control)
                        .fill(Color.appCanvas)
                )
            }

            Text(recipientLine)
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)

            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Copy Instruction") { copyReviewInstruction() }
                    .disabled(draftDecision == nil)
                Button("Send One-line") { sendReviewOneLine() }
                    .disabled(
                        draftDecision == nil
                            || project.terminalSessions.selectedSession == nil
                    )
                Spacer()
                Button("Cancel") { showReview = false }
                Button("Save Decision") { saveReview() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftDecision == nil)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Code.reviewSheetWidth)
    }

    private var draftDecision: CodeReviewDecision? {
        guard let pair = reviewPair else { return nil }
        return CodeReviewDecision(
            path: reviewPath,
            leftLabel: pair.leftLabel,
            rightLabel: pair.rightLabel,
            leftHash: pair.left.sha256,
            rightHash: pair.right.sha256,
            disposition: reviewDisposition,
            note: reviewNote.trimmingCharacters(in: .whitespacesAndNewlines),
            reference: reviewReference,
            createdAt: Date()
        )
    }

    private var recipientLine: String {
        if let session = project.terminalSessions.selectedSession {
            return "Terminal recipient: \(session.title). The one-line decision "
                + "is inserted without Enter; the full instruction is copied."
        }
        return "No terminal is selected. The instruction copies to the "
            + "clipboard."
    }

    private func pairSummary(_ pair: CodeDiffPair) -> String {
        let left = String(pair.left.sha256.prefix(7))
        let right = String(pair.right.sha256.prefix(7))
        return "\(pair.leftLabel) → \(pair.rightLabel) "
            + "(\(left) → \(right))"
    }

    private func presentReview() {
        guard let pair = document.displayedDiffPair else { return }
        reviewPair = pair
        reviewPath = document.relativePath(relativeTo: project.root)
        reviewReference = document.reference(relativeTo: project.root)
        reviewMessage = nil
        if let decision = document.reviewDecision,
           decision.leftHash == pair.left.sha256,
           decision.rightHash == pair.right.sha256 {
            reviewDisposition = decision.disposition
            reviewNote = decision.note
        } else {
            reviewDisposition = .seen
            reviewNote = ""
        }
        showReview = true
    }

    private func saveReview() {
        guard let decision = draftDecision else { return }
        Task {
            switch await workspace.recordReview(decision, in: document) {
            case .saved:
                showReview = false
            case .pairChanged:
                reviewMessage = "The pair changed while this sheet was open. "
                    + "Reopen Review to see the current pair."
            case .saveFailed(let message):
                reviewMessage = message
            }
        }
    }

    private func copyReviewInstruction() {
        guard let decision = draftDecision else { return }
        copyToPasteboard(CodeReviewInstruction.text(for: decision))
    }

    private func sendReviewOneLine() {
        guard let decision = draftDecision else { return }
        copyToPasteboard(CodeReviewInstruction.text(for: decision))
        let line = CodeReviewInstruction.oneLine(for: decision)
        let delivery = referenceDelivery()
        guard let send = delivery.send,
              let clean = CodeReferenceDelivery.sanitized(line),
              send(clean) else {
            referenceMessage = "Full instruction copied to the clipboard."
            return
        }
        referenceMessage = "Sent to the terminal; full instruction copied."
    }

    private func refusalCard(_ refusal: CodeRefusal) -> some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "doc.questionmark")
                .font(
                    .system(
                        size: AppTheme.TypeScale.displayLarge,
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(.tertiary)
            Text(refusal.explanation)
                .font(.system(size: AppTheme.TypeScale.md))
                .multilineTextAlignment(.center)
            Button("Open in Default App") {
                workspace.openInDefaultApplication(document.fileURL)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Banners

    private func readOnlyBanner(_ reason: CodeReadOnlyReason) -> some View {
        banner(
            text: reason.explanation,
            systemImage: "lock",
            tint: AppTheme.Palette.info
        )
    }

    private func noticeBanner(_ notice: String) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(Color(AppTheme.Palette.info))
            Text(notice)
                .font(.system(size: AppTheme.TypeScale.sm))
            Spacer()
            if document.pendingReview {
                Button("Review Diff") {
                    workspace.captureReviewDiff(document)
                }
            }
            Button("Reload") {
                workspace.reload(document)
            }
            Button("Dismiss") {
                workspace.dismissNotice(for: document)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.s6)
        .background(
            Color(AppTheme.Palette.info).opacity(AppTheme.Opacity.muted)
        )
    }

    private func conflictBanner(_ conflict: CodeConflict) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color(AppTheme.Palette.warning))
            Text(conflict.detail)
                .font(.system(size: AppTheme.TypeScale.sm))
            Spacer()
            Button("Reload") { workspace.reload(document) }
                .disabled(conflict.diskText == nil)
            Button("Keep Mine") { workspace.keepLocal(document) }
            Button("Save As…") {
                Task { await workspace.saveAs(document) }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.s6)
        .background(
            Color(AppTheme.Palette.warning).opacity(AppTheme.Opacity.muted)
        )
    }

    private func banner(
        text: String,
        systemImage: String,
        tint: Color,
        dismiss: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: AppTheme.TypeScale.xs))
                .lineLimit(2)
            Spacer(minLength: AppTheme.Spacing.sm)
            if let dismiss {
                Button {
                    dismiss()
                } label: {
                    Image(
                        systemName: "xmark"
                    )
                    .font(
                        .system(
                            size: AppTheme.TypeScale.xxs,
                            weight: .semibold
                        )
                    )
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.s6)
        .background(tint.opacity(AppTheme.Opacity.muted))
    }

    // MARK: Status bar

    private var statusBar: some View {
        let controller = workspace.controller(for: document)
        return HStack(spacing: AppTheme.Spacing.md) {
            Text("Ln \(controller.cursorLine), Col \(controller.cursorColumn)")
                .monospacedDigit()
            if controller.selectionLength > 0 {
                Text("\(controller.selectionLength) selected")
            }
            if let symbol = controller.symbolName {
                Text(symbol).lineLimit(1)
            }
            Spacer()
            if document.language.isPlainText == false {
                Text(document.language.displayName)
            }
            Text(controller.indentationLabel)
            Text(controller.encodingLabel)
            Text(controller.lineEndingLabel)
            if controller.highlightSnapshot?.longLineCount ?? 0 > 0 {
                Text("Long lines not highlighted")
                    .foregroundStyle(Color(AppTheme.Palette.warning))
            }
        }
        .font(.system(size: AppTheme.Code.statusFontSize))
        .foregroundStyle(.secondary)
        .padding(.horizontal, AppTheme.Spacing.sm)
        .frame(height: AppTheme.Code.statusBarHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(controller.accessibilityStatus)
    }

    // MARK: Sheets

    private var goToLineSheet: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Go to Line")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .semibold))
            TextField("Line number", text: $goToLineText)
                .textFieldStyle(.roundedBorder)
                .frame(width: AppTheme.Code.goToLineFieldWidth)
            HStack {
                Spacer()
                Button("Cancel") { showGoToLine = false }
                Button("Go") {
                    if let line = Int(goToLineText) {
                        workspace.controller(for: document).goToLine(line)
                    }
                    showGoToLine = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.xl)
    }

    private var symbolSheet: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Go to Symbol")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .semibold))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    ForEach(symbols) { symbol in
                        Button {
                            workspace.controller(for: document)
                                .goToLine(symbol.line)
                            showSymbols = false
                        } label: {
                            HStack(spacing: AppTheme.Spacing.sm) {
                                Image(systemName: symbol.kind.symbol)
                                    .foregroundStyle(.secondary)
                                Text(symbol.name)
                                Spacer()
                                Text("\(symbol.line)")
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(
                width: AppTheme.Code.symbolSheetWidth,
                height: AppTheme.Code.symbolSheetHeight
            )
            HStack {
                Spacer()
                Button("Close") { showSymbols = false }
            }
        }
        .padding(AppTheme.Spacing.lg)
    }

    // MARK: Actions

    private func loadSymbols() {
        symbolTask?.cancel()
        guard document.language.supportsOutline, document.isReady else {
            symbols = []
            return
        }
        let source = document.source
        let language = document.language
        let revision = document.revision
        symbolTask = Task { @MainActor in
            // Coalesce rapid edits; a stale scan must never replace the
            // current outline.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .utility) {
                CodeSymbolIndex.symbols(in: source, language: language)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  document.revision == revision,
                  document.language == language else {
                return
            }
            symbols = result
        }
    }

    private func deliverReference(copyOnly: Bool) {
        let reference = document.reference(relativeTo: project.root)
        let delivery = referenceDelivery()
        var effective = delivery
        if copyOnly {
            effective.send = nil
        }
        let outcome = effective.deliver(
            reference: reference,
            multiline: selectionIsMultiline
        )
        switch outcome {
        case .sent:
            referenceMessage = "Sent to the terminal."
        case .copied:
            referenceMessage = "Copied to the clipboard."
        case .rejected:
            referenceMessage = "Nothing to copy."
        }
    }

    /// A selection that spans lines goes to the clipboard; only a one-line
    /// reference may reach the terminal.
    private var selectionIsMultiline: Bool {
        guard let selection = document.selection,
              !selection.isEmpty else {
            return false
        }
        let ns = document.source as NSString
        guard selection.upperBound <= ns.length else { return false }
        return ns.substring(
            with: NSRange(
                location: selection.lowerBound,
                length: selection.count
            )
        ).contains("\n")
    }

    private func referenceDelivery() -> CodeReferenceDelivery {
        AppStateRegistry.active?.codeReferenceDelivery(
            for: project
        ) ?? CodeReferenceDelivery(
            send: nil,
            copy: copyToPasteboard
        )
    }

    private func copyDiff() {
        guard let pair = diffPair else { return }
        Task { @MainActor in
            let text = await Task.detached(priority: .userInitiated) {
                CodeDiffModel.compare(pair).unifiedText
            }.value
            copyToPasteboard(text)
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Source view

struct CodeSourceView: NSViewRepresentable {
    let document: CodeDocument
    let workspace: CodeWorkspace

    func makeNSView(context: Context) -> NSScrollView {
        let controller = workspace.controller(for: document)
        if controller.scrollView.superview != nil {
            controller.scrollView.removeFromSuperview()
        }
        controller.attach()
        return controller.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let controller = workspace.controller(for: document)
        guard nsView === controller.scrollView else { return }
        controller.syncFromDocument()
    }
}

// MARK: - Search sheet

struct CodeSearchSheet: View {
    @Bindable var workspace: CodeWorkspace
    let project: Project

    @Environment(\.dismiss) private var dismiss
    @State private var caseSensitive = false
    @State private var result: CodeSearchResult?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Search Project")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .semibold))

            HStack(spacing: AppTheme.Spacing.sm) {
                TextField("Search code", text: $workspace.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                Toggle("Match Case", isOn: $caseSensitive)
                    .toggleStyle(.checkbox)
                Button("Search") { runSearch() }
                    .disabled(workspace.searchQuery.isEmpty)
            }

            if isSearching {
                ProgressView()
            } else if let result {
                if result.isTruncated, let reason = result.truncationReason {
                    Text(reason)
                        .font(.system(size: AppTheme.TypeScale.xs))
                        .foregroundStyle(Color(AppTheme.Palette.warning))
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        ForEach(result.groupedByFile) { group in
                            Text(group.path)
                                .font(
                                    .system(
                                        size: AppTheme.TypeScale.xs,
                                        weight: .semibold
                                    )
                                )
                                .foregroundStyle(.secondary)
                            ForEach(group.matches) { match in
                                Button {
                                    open(match)
                                } label: {
                                    HStack(spacing: AppTheme.Spacing.sm) {
                                        Text("\(match.line)")
                                            .monospacedDigit()
                                            .foregroundStyle(.tertiary)
                                            .frame(
                                                width: AppTheme.Code
                                                    .diffLineNumberWidth,
                                                alignment: .trailing
                                            )
                                        Text(match.preview)
                                            .font(
                                                .system(
                                                    size: AppTheme.TypeScale.sm,
                                                    design: .monospaced
                                                )
                                            )
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .frame(
                                        maxWidth: .infinity,
                                        alignment: .leading
                                    )
                                    .frame(
                                        height: AppTheme.Code
                                            .searchResultRowHeight
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(
                    width: AppTheme.Code.symbolSheetWidth,
                    height: AppTheme.Code.symbolSheetHeight
                )
            } else {
                workspaceFileList
                Text(
                    "Search is literal and case-insensitive by default. "
                        + "Binary files, hidden files, and ignored folders "
                        + "are skipped."
                )
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
                .frame(
                    width: AppTheme.Code.symbolSheetWidth,
                    alignment: .leading
                )
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding(AppTheme.Spacing.lg)
        .onDisappear {
            searchTask?.cancel()
        }
    }

    /// Discovery makes an empty search useful: the workspace's code files
    /// are a quick-open list before any query is typed.
    private var workspaceFileList: some View {
        Group {
            if workspace.workspaceFiles.isEmpty {
                EmptyView()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        ForEach(workspace.workspaceFiles, id: \.self) { url in
                            Button {
                                workspace.open(url: url)
                                dismiss()
                            } label: {
                                Text(relativePath(for: url))
                                    .font(
                                        .system(
                                            size: AppTheme.TypeScale.sm,
                                            design: .monospaced
                                        )
                                    )
                                    .lineLimit(1)
                                    .frame(
                                        maxWidth: .infinity,
                                        alignment: .leading
                                    )
                                    .frame(
                                        height: AppTheme.Code
                                            .searchResultRowHeight
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(
                    width: AppTheme.Code.symbolSheetWidth,
                    height: AppTheme.Code.symbolSheetHeight
                )
            }
        }
    }

    private func relativePath(for url: URL) -> String {
        guard let root = workspace.workspaceRoot else {
            return url.lastPathComponent
        }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rootPath)
            ? String(url.path.dropFirst(rootPath.count))
            : url.lastPathComponent
    }

    private func runSearch() {
        guard let root = project.root else { return }
        searchTask?.cancel()
        isSearching = true
        result = nil
        let query = workspace.searchQuery
        let caseSensitive = caseSensitive
        searchTask = Task {
            let outcome = await CodeProjectSearch().search(
                root: root,
                query: query,
                caseSensitive: caseSensitive
            )
            guard !Task.isCancelled else { return }
            result = outcome
            isSearching = false
        }
    }

    private func open(_ match: CodeSearchMatch) {
        workspace.openSearchMatch(match)
        dismiss()
    }
}
