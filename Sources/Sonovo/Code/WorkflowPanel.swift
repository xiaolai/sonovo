import AppKit
import SonovoCore
import SwiftUI

/// The Workflow surface of a YAML document: a problems list above the job
/// graph. The source stays the document; this view never edits it.
struct WorkflowPanel: View {
    let workflow: Workflow
    let onRevealLine: (Int) -> Void

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            if !workflow.diagnostics.isEmpty {
                diagnosticsList
                Divider()
            }
            WorkflowChartView(workflow: workflow)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appCanvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workflow chart")
    }

    private var diagnosticsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                ForEach(workflow.diagnostics) { diagnostic in
                    Button {
                        if let line = diagnostic.line {
                            onRevealLine(line)
                        }
                    } label: {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Image(
                                systemName: diagnostic.isError
                                    ? "exclamationmark.octagon.fill"
                                    : "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(
                                diagnostic.isError
                                    ? Color(AppTheme.Palette.error)
                                    : Color(AppTheme.Palette.warning)
                            )
                            Text(diagnostic.message)
                                .font(.system(size: AppTheme.TypeScale.sm))
                                .foregroundStyle(Color(AppTheme.Palette.label))
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: AppTheme.Spacing.sm)
                            if let line = diagnostic.line {
                                Text("Line \(line)")
                                    .font(
                                        .system(
                                            size: AppTheme.TypeScale.xs,
                                            weight: .medium
                                        )
                                    )
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, AppTheme.Spacing.s6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(
                        diagnostic.line == nil
                            ? diagnostic.message
                            : "Show this line in Source"
                    )
                }
            }
        }
        .frame(
            maxHeight: AppTheme.Code.workflowDiagnosticsMaxHeight
        )
        .background(Color(AppTheme.Palette.card))
    }
}

/// Renders the workflow DOT through the Graphviz engine and shows the SVG.
/// A failed render says so; it never pretends to be a chart.
private struct WorkflowChartView: View {
    let workflow: Workflow

    @Environment(\.colorScheme) private var colorScheme
    @State private var state: RenderState = .loading

    private enum RenderState {
        case loading
        case image(NSImage)
        case failed(String)
    }

    private var variant: DiagramThemeVariant {
        colorScheme == .dark ? .dark : .light
    }

    private struct RenderID: Equatable {
        let version: String
        let variant: DiagramThemeVariant
        let workflow: Workflow
    }

    /// Equatable identity for `.task(id:)`; building the DOT belongs to the
    /// render task, not the view body.
    private var renderID: RenderID {
        RenderID(
            version: DiagramRendererPolicy.version,
            variant: variant,
            workflow: workflow
        )
    }

    var body: some View {
        Group {
            if workflow.jobs.isEmpty {
                emptyState
            } else {
                switch state {
                case .loading:
                    HStack(spacing: AppTheme.Spacing.sm) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Rendering workflow…")
                            .font(.system(size: AppTheme.TypeScale.sm))
                            .foregroundStyle(.secondary)
                    }
                case let .image(image):
                    imageView(image)
                case let .failed(message):
                    failureState(message)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: renderID) {
            await render()
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: AppTheme.TypeScale.displayMedium))
                .foregroundStyle(.tertiary)
            Text("No jobs to chart")
                .font(.system(size: AppTheme.TypeScale.md, weight: .medium))
            Text("Add a jobs: mapping to this workflow.")
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func imageView(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .padding(AppTheme.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Workflow job graph")
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: AppTheme.TypeScale.displayMedium))
                .foregroundStyle(Color(AppTheme.Palette.warning))
            Text("The chart could not be rendered")
                .font(.system(size: AppTheme.TypeScale.md, weight: .medium))
            Text(message)
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppTheme.Spacing.xl)
            Text("The YAML source is unchanged in Source view.")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func render() async {
        state = .loading
        let dot = WorkflowDOT.render(workflow, variant: variant)
        guard GraphvizDiagramPolicy.accepts(dot) else {
            state = .failed(
                "This workflow's job graph is too large for the diagram "
                    + "engine."
            )
            return
        }
        do {
            // The workflow is already parsed here, so render its DOT
            // directly; the workflow engine path would parse the YAML again.
            let svg = try await DiagramRenderer.render(
                DiagramSource(engine: .graphviz, source: dot),
                variant: variant
            )
            // `.task(id:)` cancels this view's render when the workflow
            // changes; a superseded image must not replace the newer one.
            try Task.checkCancellation()
            guard let image = NSImage(data: Data(svg.markup.utf8)) else {
                state = .failed(
                    "The diagram engine returned an image that could not "
                        + "be displayed."
                )
                return
            }
            state = .image(image)
        } catch {
            if Task.isCancelled { return }
            state = .failed(failureMessage(error))
        }
    }

    private func failureMessage(_ error: Error) -> String {
        guard let error = error as? MarkdownDiagramError else {
            return "The diagram engine reported an error."
        }
        switch error {
        case .rejectedSource:
            return "This workflow's job graph is too large for the diagram "
                + "engine."
        case .unavailable:
            return "The diagram engine is unavailable."
        case .timeout:
            return "The diagram engine timed out."
        case .loadFailed, .renderFailed:
            return "The diagram engine could not render this workflow."
        case .invalidOutput:
            return "The diagram engine returned an unreadable image."
        }
    }
}
