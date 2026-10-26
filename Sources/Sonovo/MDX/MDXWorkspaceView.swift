import SwiftUI
import SonovoMDXKit

struct MDXWorkspaceView: View {
    let workspace: MDXWorkspace
    let project: Project

    @Environment(\.colorScheme) private var colorScheme
    @State private var showPreviewWarning = false

    var body: some View {
        Group {
            if let document = workspace.selectedDocument {
                documentView(document)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appCanvas)
        .alert("Enable MDX Preview?", isPresented: $showPreviewWarning) {
            Button("Enable Preview") {
                workspace.setPreviewEnabled(true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The preview compiles the document and its local imports, "
                    + "then runs them as untrusted code in an isolated web "
                    + "view. It has no network access, no file access, and "
                    + "no access to the app. The source file is canonical; "
                    + "the preview never rewrites it."
            )
        }
    }

    // MARK: - Document

    @ViewBuilder
    private func documentView(_ document: MDXDocument) -> some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            toolbar(document)
            Divider()
            if let error = workspace.lastError {
                banner(error)
            }
            if workspace.previewEnabled {
                previewWarning
            }
            if workspace.previewEnabled {
                HSplitView {
                    sourcePane(document)
                    previewPane(document)
                }
            } else {
                sourcePane(document)
            }
        }
    }

    private func toolbar(_ document: MDXDocument) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "curlybraces.square")
                .foregroundStyle(.secondary)
            Text(document.displayName)
                .font(.system(size: AppTheme.TypeScale.md, weight: .medium))
            Text(document.isDirty ? "Edited" : "Saved")
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Save") {
                Task { await workspace.save(document) }
            }
            .disabled(!document.isDirty)
            .help("Write the source file. The preview never writes it.")
            Toggle(
                "Preview",
                isOn: Binding(
                    get: { workspace.previewEnabled },
                    set: { enabled in
                        if enabled {
                            showPreviewWarning = true
                        } else {
                            workspace.setPreviewEnabled(false)
                        }
                    }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(
                "Compile and render in an isolated, network-denied web view."
            )
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Surface.chrome)
    }

    private var previewWarning: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(AppTheme.Palette.warning)
            Text(
                "Preview runs compiled MDX as untrusted code in an isolated "
                    + "web view with no network. The source file is canonical "
                    + "and is never rewritten."
            )
            .font(.system(size: AppTheme.TypeScale.sm))
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(
            AppTheme.Palette.warning.opacity(AppTheme.Opacity.faint)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Preview enabled. Compiled MDX runs as untrusted code in an "
                + "isolated web view with no network access. The source file "
                + "is never rewritten."
        )
    }

    private func sourcePane(_ document: MDXDocument) -> some View {
        TextEditor(
            text: Binding(
                get: { document.source },
                set: { newValue in
                    document.source = newValue
                    workspace.scheduleCompile(document)
                }
            )
        )
        .font(.system(size: AppTheme.TypeScale.body, design: .monospaced))
        .scrollContentBackground(.hidden)
        .autocorrectionDisabled()
        .padding(AppTheme.Spacing.sm)
        .frame(
            minWidth: AppTheme.Layout.mdxSourceMinWidth,
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .accessibilityLabel("MDX source")
    }

    @ViewBuilder
    private func previewPane(_ document: MDXDocument) -> some View {
        switch workspace.previewState(for: document) {
        case .ready(let modules):
            if let runtime = MDXPreviewAssets.runtimeScript {
                MDXPreviewView(
                    html: MDXPreviewPage.html(
                        title: document.displayName,
                        entry: document.relativePath,
                        modules: modules,
                        runtimeScript: runtime,
                        theme: colorScheme == .dark ? .dark : .light
                    )
                )
                .frame(
                    minWidth: AppTheme.Layout.mdxPreviewMinWidth,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
                .accessibilityLabel("MDX preview")
            } else {
                unavailablePane(
                    MDXPreviewError.unavailable.localizedDescription
                )
            }
        case .compiling, .idle:
            VStack(spacing: AppTheme.Spacing.sm) {
                ProgressView()
                Text("Compiling preview…")
                    .font(.system(size: AppTheme.TypeScale.sm))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let diagnostic):
            compileErrorPane(document, diagnostic: diagnostic)
        case .unavailable(let message):
            unavailablePane(message)
        }
    }

    /// A compile error falls back to the source with the diagnostic and the
    /// failing line; the editor beside it stays editable.
    private func compileErrorPane(
        _ document: MDXDocument,
        diagnostic: MDXCompileDiagnostic
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label(
                "Preview unavailable — compile error",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: AppTheme.TypeScale.md, weight: .medium))
            .foregroundStyle(AppTheme.Palette.warning)
            Text(diagnostic.displayText)
                .font(.system(size: AppTheme.TypeScale.sm, design: .monospaced))
                .textSelection(.enabled)
            if let line = sourceLine(
                in: document.source,
                number: diagnostic.line
            ) {
                ScrollView(.horizontal) {
                    Text(line)
                        .font(
                            .system(
                                size: AppTheme.TypeScale.body,
                                design: .monospaced
                            )
                        )
                        .textSelection(.enabled)
                        .padding(AppTheme.Spacing.sm)
                }
                .background(
                    AppTheme.Palette.warning
                        .opacity(AppTheme.Opacity.subtle)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.micro))
            }
            Spacer()
        }
        .padding(AppTheme.Spacing.lg)
        .frame(
            minWidth: AppTheme.Layout.mdxPreviewMinWidth,
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Compile error. \(diagnostic.displayText)")
    }

    private func unavailablePane(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label(
                "Preview unavailable",
                systemImage: "exclamationmark.octagon.fill"
            )
            .font(.system(size: AppTheme.TypeScale.md, weight: .medium))
            .foregroundStyle(AppTheme.Palette.error)
            Text(message)
                .font(.system(size: AppTheme.TypeScale.sm))
                .textSelection(.enabled)
            Spacer()
        }
        .padding(AppTheme.Spacing.lg)
        .frame(
            minWidth: AppTheme.Layout.mdxPreviewMinWidth,
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview unavailable. \(message)")
    }

    private func sourceLine(in source: String, number: Int?) -> String? {
        guard let number, number > 0 else { return nil }
        let lines = source.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard lines.indices.contains(number - 1) else { return nil }
        return String(lines[number - 1])
    }

    private func banner(_ text: String) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(AppTheme.Palette.warning)
            Text(text)
                .font(.system(size: AppTheme.TypeScale.sm))
            Spacer()
            Button("Dismiss") { workspace.dismissError() }
                .controlSize(.small)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Palette.warning.opacity(AppTheme.Opacity.faint))
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "curlybraces.square")
                .font(
                    .system(
                        size: AppTheme.TypeScale.displayLarge,
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(.tertiary)
            Text("No MDX Document")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))
            Text("Open an .mdx or .jsx file from the project navigator.")
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
