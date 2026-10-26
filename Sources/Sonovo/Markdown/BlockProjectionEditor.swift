import AppKit
import Observation
import SonovoCore
import SwiftUI

/// The model behind one block's in-place source editor.
///
/// It holds a draft and nothing else. Saving asks the document to replace
/// exactly the captured block range; a refusal keeps the draft and shows why,
/// so an IME composition or a concurrent edit never loses text silently.
@MainActor
@Observable
final class BlockProjectionEditorModel {
    var text: String
    var error: String?
    /// True while an input-method composition owns marked text. Saving then
    /// would write a partial composition, so it refuses.
    var hasMarkedText = false

    private let commit: (String) -> Bool

    init(text: String, commit: @escaping (String) -> Bool) {
        self.text = text
        self.commit = commit
    }

    @discardableResult
    func save() -> Bool {
        guard !hasMarkedText else {
            error = "Finish composing text before saving."
            return false
        }
        guard commit(text) else {
            error = "The block changed since it opened. "
                + "Close the editor and try again."
            return false
        }
        error = nil
        return true
    }
}

/// One block's source, editable in place over the rendered projection.
///
/// The model is supplied by the owner, not created here: the same draft can
/// be re-presented in a second location when an external change moves its
/// block, and a `@State` model inside this view would be recreated with the
/// original slice.
struct BlockProjectionEditor: View {
    let title: String
    @Bindable var model: BlockProjectionEditorModel
    let onCancel: () -> Void

    init(
        title: String,
        model: BlockProjectionEditorModel,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.model = model
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(title)
                    .font(
                        .system(size: AppTheme.TypeScale.xxs, weight: .semibold)
                    )
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Source projection")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.tertiary)
            }
            ProjectionSourceTextView(
                text: $model.text,
                hasMarkedText: $model.hasMarkedText,
                onSave: save,
                onCancel: onCancel
            )
            .frame(
                minHeight: AppTheme.MarkdownChrome.BlockEditor.minHeight,
                maxHeight: AppTheme.MarkdownChrome.BlockEditor.maxHeight
            )
            .background(AppTheme.MarkdownChrome.BlockEditor.background)
            .clipShape(
                RoundedRectangle(cornerRadius: AppTheme.Radius.micro)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.micro)
                    .stroke(
                        AppTheme.MarkdownChrome.BlockEditor.border,
                        lineWidth: AppTheme.BorderWidth.hairline
                    )
            }
            if let error = model.error {
                Text(error)
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(AppTheme.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("⌘↩ Save · Esc Cancel")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.return, modifiers: [.command])
            }
            .font(.system(size: AppTheme.TypeScale.xs))
        }
        .padding(AppTheme.MarkdownChrome.BlockEditor.padding)
        .background(AppTheme.Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func save() {
        if model.save() {
            onCancel()
        }
    }
}

// MARK: - Text view

private struct ProjectionSourceTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var hasMarkedText: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(
            ofSize: AppTheme.Reading.sourceSize,
            weight: .regular
        )
        textView.textContainerInset = NSSize(
            width: AppTheme.Spacing.xs,
            height: AppTheme.Spacing.xs
        )
        textView.textContainer?.lineFragmentPadding =
            AppTheme.Editor.lineFragmentPadding
        textView.string = text
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel("Block source")
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }
        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
        }
        context.coordinator.syncMarkedText(from: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ProjectionSourceTextView

        init(parent: ProjectionSourceTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            parent.text = textView.string
            syncMarkedText(from: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            syncMarkedText(from: textView)
        }

        func textView(
            _ view: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            syncMarkedText(from: view)
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)),
               NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                parent.onSave()
                return true
            }
            return false
        }

        func syncMarkedText(from textView: NSTextView) {
            let marked = textView.hasMarkedText()
            if parent.hasMarkedText != marked {
                parent.hasMarkedText = marked
            }
        }
    }
}
