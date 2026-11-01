import Foundation

/// The two palettes a diagram is rendered for.
///
/// The raw value is what the renderer reports in cache keys and diagnostics;
/// the engine theme names are app-level translations, so the cache does not
/// change when a bundled engine renames a theme.
public enum DiagramThemeVariant: String, CaseIterable, Sendable {
    case light
    case dark
}

/// The Mermaid name is kept for the RB-23 call sites and tests; both names
/// describe the same two palettes.
public typealias MermaidThemeVariant = DiagramThemeVariant

/// A renderer that produces one diagram format.
public enum DiagramEngine: String, CaseIterable, Sendable {
    case mermaid
    case graphviz
    case markmap
    case svg
    /// A GitHub Actions workflow chart. Its source is DOT generated from the
    /// workflow YAML and rendered by the Graphviz engine, but the engine name
    /// stays distinct so the cache, the label, and the copy source agree.
    case workflow
}

/// A fenced block that a diagram renderer owns, with its source.
public struct DiagramSource: Equatable, Sendable {
    public let engine: DiagramEngine
    public let source: String

    public init(engine: DiagramEngine, source: String) {
        self.engine = engine
        self.source = source
    }
}
