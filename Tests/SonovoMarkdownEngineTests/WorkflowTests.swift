import Foundation
import Testing
@testable import SonovoMarkdownEngine
import SonovoDiagramEngine

@Suite("Workflow Markdown fence integration")
struct WorkflowMarkdownFenceTests {
    // MARK: - Fence dispatch

    private func codeBlock(_ source: String) throws -> CodeBlock {
        let ast = MarkdownSyntaxAugmenter()
            .augment(MarkdownParser.parseCanonical(source))
        guard case let .codeBlock(code, _) = ast.blocks.first else {
            Issue.record("expected a code block, got \(ast.blocks)")
            throw TestFailure()
        }
        return code
    }

    private struct TestFailure: Error {}

    @Test("A workflow-shaped YAML fence becomes a workflow chart")
    func fenceDispatch() throws {
        let code = try codeBlock(
            "```yaml\non: push\njobs:\n  build:\n    runs-on: x\n```\n"
        )
        let diagram = try #require(DiagramPolicy.source(from: code))
        #expect(diagram.engine == .workflow)
        // The fence keeps its YAML; the renderer converts it to DOT off the
        // main actor.
        #expect(
            diagram.source
                == "on: push\njobs:\n  build:\n    runs-on: x\n"
        )
        let dot = try #require(WorkflowDiagramPolicy.dot(from: diagram.source))
        #expect(dot.contains("digraph workflow"))
        #expect(dot.contains("build"))
    }

    @Test("The yml info token dispatches the same way")
    func ymlFenceDispatch() throws {
        let code = try codeBlock(
            "```yml\non: push\njobs:\n  build:\n    runs-on: x\n```\n"
        )
        let diagram = try #require(DiagramPolicy.source(from: code))
        #expect(diagram.engine == .workflow)
    }

    @Test("Ordinary YAML stays a code block")
    func plainYAMLIsNotAChart() throws {
        let code = try codeBlock("```yaml\nname: CI\non: push\n```\n")
        #expect(DiagramPolicy.source(from: code) == nil)
    }

    @Test("An explicit workflow fence does not require the shape")
    func explicitFence() throws {
        let code = try codeBlock(
            "```workflow\njobs:\n  build:\n    runs-on: x\n```\n"
        )
        let diagram = try #require(DiagramPolicy.source(from: code))
        #expect(diagram.engine == .workflow)
    }

    @Test("An explicit workflow fence with no jobs is not a chart")
    func explicitFenceWithoutJobs() throws {
        let code = try codeBlock("```workflow\nname: CI\n```\n")
        #expect(DiagramPolicy.source(from: code) == nil)
    }
}
