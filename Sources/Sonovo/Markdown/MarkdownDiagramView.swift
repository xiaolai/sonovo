import AppKit
import SonovoCore
import SwiftUI

/// A fenced diagram in the reader.
///
/// The diagram is rendered off the view's own path: this view asks the engine
/// renderer for a sanitized SVG, turns it into an `NSImage`, and falls back to
/// the ordinary fenced code block whenever anything fails. The card stays the
/// code block's ground and radius so a document that mixes diagrams and code
/// reads as one surface. A raw SVG fence is the author's own artwork, so its
/// card uses the light paper surface even in a dark reader.
struct MarkdownDiagramView: View {
    let code: CodeBlock
    let diagram: DiagramSource
    let theme: MarkdownTheme
    let palette: ThemePalette
    let highlightQuery: String?

    @Environment(\.colorScheme) private var colorScheme
    @State private var state: RenderState = .loading
    @State private var copied = false
    /// Workflow problems, when this fence is a workflow chart. A fence has no
    /// source editor to underline, so the card reports the count and lists
    /// the messages on hover.
    @State private var problems: [WorkflowDiagnostic] = []

    private enum RenderState {
        case loading
        case diagram(NSImage, SanitizedSVG)
        case fallback
    }

    private var variant: DiagramThemeVariant {
        colorScheme == .dark ? .dark : .light
    }

    /// The renderer version is part of the identity: an upgrade must rerender,
    /// not reuse a diagram from the previous pipeline.
    private var taskID: String {
        "\(DiagramRendererPolicy.version)\u{1F}\(diagram.engine.rawValue)"
            + "\u{1F}\(variant.rawValue)\u{1F}\(diagram.source)"
    }

    private var label: String {
        switch diagram.engine {
        case .graphviz: "dot"
        case .workflow: "workflow"
        default: diagram.engine.rawValue
        }
    }

    private var cardGround: Color {
        diagram.engine == .svg
            ? theme.palette(for: .light).paper.color
            : palette.codeGround.color
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                placeholder
            case let .diagram(image, svg):
                diagramCard(image, svg)
            case .fallback:
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    if !problems.isEmpty {
                        problemsBadge
                            .padding(.horizontal, theme.codePadding)
                    }
                    MarkdownCodeBlockView(
                        code: code,
                        theme: theme,
                        palette: palette,
                        highlightQuery: highlightQuery
                    )
                }
            }
        }
        .task(id: taskID) {
            if diagram.engine == .workflow {
                let parsed = await Task.detached(priority: .userInitiated) {
                    WorkflowDiagramPolicy.workflow(from: code.code)
                }.value
                if Task.isCancelled { return }
                problems = parsed.diagnostics
            } else {
                problems = []
            }
            await render()
        }
    }

    // MARK: States

    private var placeholder: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Rendering diagram…")
                .font(theme.uiFont.font(size: theme.captionSize))
                .foregroundStyle(palette.secondaryInk.color)
            Spacer(minLength: AppTheme.Spacing.sm)
        }
        .padding(theme.codePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardGround)
        .clipShape(
            RoundedRectangle(cornerRadius: theme.codeRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rendering \(label) diagram")
    }

    private var problemsBadge: some View {
        Label(
            "\(problems.count) "
                + (problems.count == 1 ? "problem" : "problems"),
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(
            theme.uiFont.font(
                size: theme.captionSize,
                weight: .medium
            )
        )
        .foregroundStyle(palette.warning.color)
        .help(problems.map(\.message).joined(separator: "\n"))
        .accessibilityLabel(
            problems.map(\.message).joined(separator: ", ")
        )
    }

    private func diagramCard(_ image: NSImage, _ svg: SanitizedSVG) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(label)
                    .font(
                        theme.uiFont.font(
                            size: theme.captionSize,
                            weight: .medium
                        )
                    )
                    .foregroundStyle(
                        diagram.engine == .svg
                            ? theme.palette(for: .light).secondaryInk.color
                            : palette.secondaryInk.color
                    )
                if !problems.isEmpty {
                    problemsBadge
                }
                Spacer(minLength: AppTheme.Spacing.sm)
                Button {
                    copySource()
                } label: {
                    Label(
                        copied ? "Copied" : "Copy",
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                    .font(theme.uiFont.font(size: theme.captionSize))
                    .foregroundStyle(
                        copied
                            ? AppTheme.MarkdownChrome.CodeHeader.feedback
                            : (
                                diagram.engine == .svg
                                    ? theme.palette(for: .light).secondaryInk
                                        .color
                                    : palette.secondaryInk.color
                            )
                    )
                }
                .buttonStyle(.plain)
                .help("Copy the diagram source")
                .accessibilityLabel("Copy diagram source")
            }
            diagramImage(image, svg)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(theme.codePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardGround)
        .clipShape(
            RoundedRectangle(cornerRadius: theme.codeRadius, style: .continuous)
        )
        .contextMenu {
            Button("Copy Diagram Source") { copySource() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(label) diagram")
    }

    /// A diagram scales down to the measure but never up past its natural
    /// size, so a small flowchart keeps its authored proportions.
    @ViewBuilder
    private func diagramImage(_ image: NSImage, _ svg: SanitizedSVG) -> some View {
        if let width = svg.width, width > 0 {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: CGFloat(width))
        } else {
            Image(nsImage: image)
        }
    }

    // MARK: Actions

    private func render() async {
        state = .loading
        do {
            let svg = try await DiagramRenderer.render(
                diagram,
                variant: variant
            )
            // `.task(id:)` cancels this task when the diagram changes; the
            // renderer itself is not cancellation-aware, so the result of a
            // superseded render must not replace the newer diagram.
            try Task.checkCancellation()
            guard let image = NSImage(data: Data(svg.markup.utf8)) else {
                state = .fallback
                return
            }
            state = .diagram(image, svg)
        } catch {
            if Task.isCancelled { return }
            state = .fallback
        }
    }

    private func copySource() {
        // A workflow source is the fenced YAML itself; the DOT is generated
        // by the renderer and never stored here.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagram.source, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(
                for: .seconds(
                    AppTheme.MarkdownChrome.CodeHeader.copyFeedbackSeconds
                )
            )
            copied = false
        }
    }
}
