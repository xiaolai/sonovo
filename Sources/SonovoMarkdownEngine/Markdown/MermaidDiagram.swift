import SonovoDiagramEngine
import SonovoDomainTypes
import CryptoKit
import Foundation

/// Dispatches a fenced code block to the engine named by its info string.
public enum DiagramPolicy {
    /// The first whitespace-separated token of the fence info string,
    /// lowercased. A tab separates tokens exactly as a space does.
    static func infoToken(_ code: CodeBlock) -> String {
        (code.info ?? code.language ?? "")
            .split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased() ?? ""
    }

    public static func source(from code: CodeBlock) -> DiagramSource? {
        guard code.fenced else { return nil }
        let info = infoToken(code)
        switch info {
        case "mermaid":
            guard MermaidDiagramPolicy.accepts(code.code) else { return nil }
            return DiagramSource(engine: .mermaid, source: code.code)
        case "dot", "graphviz":
            guard GraphvizDiagramPolicy.accepts(code.code) else { return nil }
            return DiagramSource(engine: .graphviz, source: code.code)
        case "markmap":
            guard MarkmapDiagramPolicy.accepts(code.code) else { return nil }
            return DiagramSource(engine: .markmap, source: code.code)
        case "svg":
            guard SVGFencePolicy.accepts(code.code) else { return nil }
            return DiagramSource(engine: .svg, source: code.code)
        case "yaml", "yml":
            return WorkflowDiagramPolicy.diagramSource(
                from: code.code,
                explicit: false
            )
        case "workflow":
            return WorkflowDiagramPolicy.diagramSource(
                from: code.code,
                explicit: true
            )
        default:
            return nil
        }
    }
}

/// A YAML fence becomes a workflow chart only when its content is a GitHub
/// Actions workflow. Any other YAML stays a code block.
///
/// Detection here is lexical and never runs the YAML parser: this policy is
/// called while a Markdown view body is evaluated. The workflow source stays
/// YAML; `DiagramRenderer` converts it to DOT off the main actor.

public typealias WorkflowDiagramPolicy = SonovoDiagramEngine.WorkflowDiagramPolicy
public typealias GraphvizDiagramPolicy = SonovoDiagramEngine.GraphvizDiagramPolicy
public typealias MarkmapDiagramPolicy = SonovoDiagramEngine.MarkmapDiagramPolicy
public typealias SVGFencePolicy = SonovoDiagramEngine.SVGFencePolicy
public typealias MermaidDiagramPolicy = SonovoDiagramEngine.MermaidDiagramPolicy
public typealias MermaidDiagramKey = SonovoDiagramEngine.MermaidDiagramKey
public typealias DiagramKey = SonovoDiagramEngine.DiagramKey
public typealias DiagramRendererPolicy = SonovoDiagramEngine.DiagramRendererPolicy
public typealias MermaidRendererPolicy = SonovoDiagramEngine.MermaidRendererPolicy
public typealias GraphvizRendererPolicy = SonovoDiagramEngine.GraphvizRendererPolicy
public typealias MarkmapRendererPolicy = SonovoDiagramEngine.MarkmapRendererPolicy

extension SonovoDiagramEngine.MermaidDiagramPolicy {
    public static func source(from code: CodeBlock) -> String? {
        guard code.fenced else { return nil }
        guard DiagramPolicy.infoToken(code) == "mermaid" else { return nil }
        guard accepts(code.code) else { return nil }
        return code.code
    }
}
