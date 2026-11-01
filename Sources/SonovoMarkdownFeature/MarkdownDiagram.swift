import AppKit
import SonovoMarkdownEngine
import SonovoDomainTypes
import SonovoDiagramEngine
import SonovoDiagramUI

// MARK: - AST collection

package enum MarkdownDiagramNodes {
    /// Every distinct diagram in the document, in document order.
    package static func sources(from ast: SonovoAST) -> [DiagramSource] {
        var seen = Set<String>()
        var result: [DiagramSource] = []

        func add(_ code: CodeBlock) {
            guard let diagram = DiagramPolicy.source(from: code) else {
                return
            }
            let identity = diagram.engine.rawValue + "\u{1F}" + diagram.source
            guard seen.insert(identity).inserted else { return }
            result.append(diagram)
        }

        func walk(_ blocks: [Block]) {
            for block in blocks {
                switch block {
                case let .codeBlock(code, _):
                    add(code)
                case let .blockQuote(children, _):
                    walk(children)
                case let .list(list, _):
                    for item in list.items { walk(item.blocks) }
                case let .details(details, _):
                    walk(details.blocks)
                default:
                    break
                }
            }
        }

        walk(ast.blocks)
        return result
    }

    /// The Mermaid slice, for the E2E marker.
    package static func mermaidSources(from ast: SonovoAST) -> [String] {
        sources(from: ast)
            .filter { $0.engine == .mermaid }
            .map(\.source)
    }
}

// MARK: - Export assets

@MainActor
package enum MarkdownDiagramAssets {
    /// Renders each diagram once for both palettes. A diagram that fails to
    /// render is absent, so the exporter falls back to the code block.
    package static func build(
        from ast: SonovoAST,
        includeDark: Bool,
        byteBudget: Int = MarkdownLimits.maxDiagramExportBytes,
        deadline: Date? = nil
    ) async -> [String: MarkdownDiagramAsset] {
        let sources = MarkdownDiagramNodes.sources(from: ast)
            .prefix(MarkdownLimits.maxRenderedDiagrams)
        guard !sources.isEmpty else { return [:] }

        // One wall clock for the whole build. Every diagram used to get a
        // fresh 10 s, so 200 diagrams could hold an export for half an hour
        // before the PDF budget even started.
        let budgetDeadline = deadline ?? Date().addingTimeInterval(
            MarkdownLimits.pdfRenderTimeoutSeconds
        )
        var assets: [String: MarkdownDiagramAsset] = [:]
        assets.reserveCapacity(sources.count)
        var totalBytes = 0

        diagramLoop: for diagram in sources {
            let remaining = budgetDeadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let timeout = Duration.seconds(
                min(MarkdownLimits.mermaidRenderTimeoutSeconds, remaining)
            )
            let light: SanitizedSVG
            do {
                light = try await DiagramRenderer.render(
                    diagram,
                    variant: .light,
                    timeout: timeout
                )
            } catch let error as MarkdownDiagramError {
                // A timeout means the shared budget is spent; trying the
                // next diagram would only stall the export again.
                if error == .timeout { break }
                continue
            } catch {
                continue
            }
            var dark = light.markup
            if includeDark, diagram.engine != .svg {
                let darkRemaining = budgetDeadline.timeIntervalSinceNow
                guard darkRemaining > 0 else { break }
                let darkTimeout = Duration.seconds(
                    min(
                        MarkdownLimits.mermaidRenderTimeoutSeconds,
                        darkRemaining
                    )
                )
                do {
                    let rendered = try await DiagramRenderer.render(
                        diagram,
                        variant: .dark,
                        timeout: darkTimeout
                    )
                    dark = rendered.markup
                } catch let error as MarkdownDiagramError {
                    if error == .timeout { break diagramLoop }
                } catch {
                    // Keep the light variant.
                }
            }
            let bytes = light.markup.utf8.count + dark.utf8.count
            if totalBytes + bytes > byteBudget {
                break
            }
            assets[DiagramKey.documentKey(
                engine: diagram.engine,
                source: diagram.source
            )] = MarkdownDiagramAsset(
                engine: diagram.engine,
                lightSVG: light.markup,
                darkSVG: dark,
                width: light.width,
                height: light.height
            )
            totalBytes += bytes
        }
        return assets
    }
}

/// The RB-23 name.
@MainActor
package enum MarkdownMermaidAssets {
    package static func build(
        from ast: SonovoAST,
        includeDark: Bool,
        byteBudget: Int = MarkdownLimits.maxDiagramExportBytes
    ) async -> [String: MarkdownMermaidAsset] {
        await MarkdownDiagramAssets.build(
            from: ast,
            includeDark: includeDark,
            byteBudget: byteBudget
        )
    }
}
