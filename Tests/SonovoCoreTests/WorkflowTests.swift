import Foundation
import Testing
@testable import SonovoCore

@Suite("Workflow charts")
struct WorkflowTests {
    // MARK: - Detection

    @Test("Only a file directly inside .github/workflows is a candidate")
    func pathDetection() {
        #expect(WorkflowDetection.isWorkflowPath(".github/workflows/ci.yml"))
        #expect(
            WorkflowDetection.isWorkflowPath("/repo/.github/workflows/ci.yaml")
        )
        #expect(
            WorkflowDetection.isWorkflowPath(
                "/repo/.GITHUB/Workflows/CI.YML"
            )
        )
        #expect(
            !WorkflowDetection.isWorkflowPath(
                "/repo/.github/workflows/sub/ci.yml"
            )
        )
        #expect(!WorkflowDetection.isWorkflowPath("/repo/workflows/ci.yml"))
        #expect(
            !WorkflowDetection.isWorkflowPath("/repo/.github/workflows/ci.md")
        )
        #expect(!WorkflowDetection.isWorkflowPath("/repo/.github/ci.yml"))
    }

    @Test("CRLF line endings still satisfy the shape")
    func crlfShape() {
        let source = "on: push\r\njobs:\r\n  build:\r\n    runs-on: x\r\n"
        #expect(WorkflowDetection.hasWorkflowShape(source))
    }

    @Test("An escaped double-quoted key is decoded")
    func escapedQuotedKey() {
        let source = "\"\\u006fn\": push\njobs: {}\n"
        #expect(WorkflowDetection.hasWorkflowShape(source))
    }


    @Test("The workflow shape requires on: and jobs: at column zero")
    func shapeDetection() {
        let workflow = """
            name: CI
            on: push
            jobs:
              build:
                runs-on: macos-15
            """
        #expect(WorkflowDetection.hasWorkflowShape(workflow))
        #expect(WorkflowDetection.hasWorkflowShape("on: push\njobs: {}\n"))
        #expect(
            WorkflowDetection.hasWorkflowShape("\"on\": push\n'jobs': {}\n")
        )
        #expect(!WorkflowDetection.hasWorkflowShape("on: push\n"))
        #expect(!WorkflowDetection.hasWorkflowShape("jobs:\n  a: {}\n"))
        #expect(
            !WorkflowDetection.hasWorkflowShape("  on: push\n  jobs: {}\n")
        )
        #expect(
            !WorkflowDetection.hasWorkflowShape("# on: push\n# jobs: {}\n")
        )
        #expect(!WorkflowDetection.hasWorkflowShape("on:push\njobs: {}\n"))
        #expect(!WorkflowDetection.hasWorkflowShape(""))
    }

    @Test("Empty, NUL, and oversized sources are refused")
    func sourceCaps() {
        #expect(!WorkflowDetection.acceptsSource("  \n"))
        #expect(!WorkflowDetection.acceptsSource("on:\u{0}"))
        #expect(
            !WorkflowDetection.acceptsSource(
                String(
                    repeating: "a",
                    count: WorkflowDetection.maxSourceBytes + 1
                )
            )
        )
        #expect(WorkflowDetection.acceptsSource("on: push\njobs: {}\n"))
    }

    // MARK: - Parsing

    private let fixture = """
        name: CI
        on:
          push:
            branches: [main]
        jobs:
          build:
            runs-on: macos-15
            steps:
              - uses: actions/checkout@v5
          test:
            name: Run tests
            strategy:
              matrix:
                os: [macos-15]
                include:
                  - os: macos-14
            runs-on: [self-hosted, macOS]
            needs: [build]
            steps:
              - run: swift test
              - run: echo done
          package:
            needs:
              - build
              - test
            uses: owner/repo/.github/workflows/package.yml@main
        """

    @Test("Jobs, needs, runners, steps, and matrix are read")
    func parsesJobs() throws {
        let workflow = WorkflowParser.parse(fixture)
        #expect(workflow.name == "CI")
        #expect(workflow.diagnostics.isEmpty)
        #expect(workflow.jobs.map(\.id) == ["build", "test", "package"])

        let build = try #require(workflow.jobs.first { $0.id == "build" })
        #expect(build.runsOn == ["macos-15"])
        #expect(build.stepCount == 1)
        #expect(build.needs.isEmpty)
        #expect(build.line == 6)

        let test = try #require(workflow.jobs.first { $0.id == "test" })
        #expect(test.name == "Run tests")
        #expect(test.runsOn == ["self-hosted", "macOS"])
        #expect(test.needs == ["build"])
        #expect(test.stepCount == 2)
        #expect(test.matrixKeys == ["os"])
        #expect(test.line == 10)

        let package = try #require(workflow.jobs.first { $0.id == "package" })
        #expect(package.needs == ["build", "test"])
        #expect(
            package.uses
                == "owner/repo/.github/workflows/package.yml@main"
        )
        #expect(package.runsOn.isEmpty)
        #expect(package.stepCount == 0)
        #expect(package.line == 22)
    }

    @Test("An unknown need is an error at the needs entry")
    func unknownNeed() throws {
        let source = """
            on: push
            jobs:
              build:
                runs-on: macos-15
              deploy:
                needs: [build, missing]
                runs-on: macos-15
            """
        let workflow = WorkflowParser.parse(source)
        let diagnostic = try #require(
            workflow.diagnostics.first { $0.code == .unknownNeed }
        )
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.jobIDs == ["deploy"])
        #expect(diagnostic.line == 6)
        #expect(diagnostic.message.contains("missing"))
        #expect(workflow.problemJobIDs == ["deploy"])
    }

    @Test("A dependency cycle is reported once for the whole ring")
    func dependencyCycle() throws {
        let source = """
            on: push
            jobs:
              a:
                needs: [c]
              b:
                needs: [a]
              c:
                needs: [b]
            """
        let workflow = WorkflowParser.parse(source)
        let cycles = workflow.diagnostics.filter {
            $0.code == .dependencyCycle
        }
        #expect(cycles.count == 1)
        let cycle = try #require(cycles.first)
        #expect(Set(cycle.jobIDs) == ["a", "b", "c"])
        #expect(cycle.message.hasPrefix("Dependency cycle: "))
        #expect(cycle.message.hasSuffix(" → a."))
        #expect(workflow.problemJobIDs == ["a", "b", "c"])
        #expect(workflow.jobs.count == 3)
    }

    @Test("A self-dependency is a cycle")
    func selfCycle() {
        let source = """
            on: push
            jobs:
              loop:
                needs: [loop]
            """
        let workflow = WorkflowParser.parse(source)
        let cycle = workflow.diagnostics.first {
            $0.code == .dependencyCycle
        }
        #expect(cycle?.message == "Dependency cycle: loop → loop.")
    }

    @Test("A duplicate job id is a duplicate-key error")
    func duplicateJob() throws {
        let source = """
            on: push
            jobs:
              build:
                runs-on: macos-14
              build:
                runs-on: macos-15
            """
        let workflow = WorkflowParser.parse(source)
        let duplicate = try #require(
            workflow.diagnostics.first { $0.code == .duplicateKey }
        )
        #expect(duplicate.severity == .error)
        #expect(duplicate.message.contains("build"))
        // Yams reports the first occurrence's mark; the duplicate's line is
        // not available, so nothing is underlined.
        #expect(duplicate.line == nil)
        #expect(workflow.jobs.isEmpty)
    }

    @Test("Malformed and non-workflow documents report a diagnostic")
    func invalidDocuments() throws {
        let invalid = WorkflowParser.parse("jobs: [unclosed\n")
        #expect(invalid.jobs.isEmpty)
        #expect(invalid.diagnostics.contains { $0.code == .invalidYAML })

        let missing = WorkflowParser.parse("on: push\n")
        #expect(missing.diagnostics.contains { $0.code == .missingJobs })

        let notMapping = WorkflowParser.parse("- a\n- b\n")
        #expect(notMapping.diagnostics.contains { $0.code == .notAMapping })

        let jobsNotMapping = WorkflowParser.parse("on: push\njobs: [a]\n")
        #expect(
            jobsNotMapping.diagnostics.contains { $0.code == .jobsNotAMapping }
        )

        let invalidJob = WorkflowParser.parse("on: push\njobs:\n  build: 3\n")
        #expect(
            invalidJob.diagnostics.contains { $0.code == .invalidJob }
        )
        #expect(invalidJob.jobs.map(\.id) == ["build"])
    }

    @Test("A NUL byte is refused before parsing")
    func unreadableSource() {
        let source = "on: push\njobs: \u{0}\n"
        #expect(!WorkflowDetection.acceptsSource(source))
        let workflow = WorkflowParser.parse(source)
        #expect(
            workflow.diagnostics.contains { $0.code == .unreadableSource }
        )
        #expect(workflow.jobs.isEmpty)
    }

    @Test("Deep nesting fails in the parser instead of crashing")
    func deepNesting() {
        let source = "on: push\njobs:\n  build: "
            + String(repeating: "[", count: 2_000) + "\n"
        let workflow = WorkflowParser.parse(source)
        #expect(
            workflow.diagnostics.contains { $0.code == .invalidYAML }
        )
        #expect(workflow.jobs.isEmpty)
    }

    @Test("Long identifiers are shortened in diagnostic messages")
    func longDiagnosticIdentifier() throws {
        let need = String(repeating: "n", count: 900)
        let source = "on: push\njobs:\n  build:\n"
            + "    needs: [\(need)]\n"
            + "    runs-on: x\n"
        let workflow = WorkflowParser.parse(source)
        let diagnostic = try #require(
            workflow.diagnostics.first { $0.code == .unknownNeed }
        )
        #expect(diagnostic.message.count < 300)
        #expect(diagnostic.message.hasSuffix("…”, which is not defined."))
    }

    @Test("The job count is capped")
    func jobLimit() {
        var source = "on: push\njobs:\n"
        for index in 0...WorkflowDetection.maxJobs {
            source += "  job\(index):\n    runs-on: macos-15\n"
        }
        let workflow = WorkflowParser.parse(source)
        #expect(workflow.jobs.count == WorkflowDetection.maxJobs)
        #expect(
            workflow.diagnostics.contains { $0.code == .jobLimit }
        )
    }

    @Test("Jobs past the chart cap still count as defined")
    func jobsPastTheCapAreDefined() {
        var source = "on: push\njobs:\n  job0:\n    runs-on: x\n"
            + "    needs: [job\(WorkflowDetection.maxJobs)]\n"
        for index in 1...WorkflowDetection.maxJobs {
            source += "  job\(index):\n    runs-on: x\n"
        }
        let workflow = WorkflowParser.parse(source)
        #expect(workflow.jobs.count == WorkflowDetection.maxJobs)
        #expect(
            !workflow.diagnostics.contains { $0.code == .unknownNeed }
        )
        #expect(
            workflow.diagnostics.contains { $0.code == .jobLimit }
        )
    }

    @Test("Unknown needs are capped with a summary warning")
    func unknownNeedCap() {
        let needs = (0..<200).map { "n\($0)" }.joined(separator: ", ")
        let source = "on: push\njobs:\n  build:\n    runs-on: x\n"
            + "    needs: [\(needs)]\n"
        let workflow = WorkflowParser.parse(source)
        let unknown = workflow.diagnostics.filter {
            $0.code == .unknownNeed
        }
        #expect(unknown.count == WorkflowParser.maxUnknownNeedDiagnostics)
        #expect(
            workflow.diagnostics.contains { $0.code == .diagnosticLimit }
        )
    }

    @Test("Keys that share text but not a tag are reported, not merged")
    func taggedDuplicateJobID() {
        let source = "on: push\njobs:\n  on:\n    needs: [b]\n"
            + "  \"on\": {}\n  b:\n    needs: [on]\n"
        let workflow = WorkflowParser.parse(source)
        #expect(workflow.jobs.map(\.id) == ["on", "b"])
        #expect(workflow.diagnostics.contains { $0.code == .duplicateKey })
        #expect(workflow.diagnostics.contains { $0.code == .dependencyCycle })
    }

    @Test("A non-scalar job identifier is reported")
    func nonScalarJobIdentifier() {
        let source = "on: push\njobs:\n  [build]: {runs-on: x}\n"
        let workflow = WorkflowParser.parse(source)
        #expect(workflow.jobs.isEmpty)
        #expect(workflow.diagnostics.contains { $0.code == .invalidJob })
    }

    @Test("A tagged mapping key is not a job id")
    func taggedMappingKey() {
        let source = "on: push\njobs:\n  {{=: build}: {}}\n"
        let workflow = WorkflowParser.parse(source)
        #expect(workflow.jobs.isEmpty)
        #expect(workflow.diagnostics.contains { $0.code == .invalidJob })
    }

    @Test("A malformed needs value is reported")
    func malformedNeeds() {
        let mapping = WorkflowParser.parse(
            "on: push\njobs:\n  build: {}\n  deploy:\n"
                + "    needs: {build: true}\n"
        )
        #expect(mapping.diagnostics.contains { $0.code == .invalidNeeds })

        let nested = WorkflowParser.parse(
            "on: push\njobs:\n  build: {}\n  deploy:\n"
                + "    needs: [[build]]\n"
        )
        #expect(nested.diagnostics.contains { $0.code == .invalidNeeds })
    }

    @Test("A tagged mapping needs value is not a job name")
    func taggedNeedsValue() {
        let source = "on: push\njobs:\n  build: {}\n  deploy:\n"
            + "    needs: {=: build}\n"
        let workflow = WorkflowParser.parse(source)
        #expect(workflow.diagnostics.contains { $0.code == .invalidNeeds })
    }

    @Test("A newline-only job identifier is rejected")
    func newlineJobIdentifier() {
        let source = "on: push\njobs:\n  \"\\n\": {}\n"
        let workflow = WorkflowParser.parse(source)
        #expect(workflow.jobs.isEmpty)
        #expect(workflow.diagnostics.contains { $0.code == .invalidJob })
    }

    @Test("An invalid YAML diagnostic carries its source line")
    func invalidYAMLLine() throws {
        let source = "jobs:\n  build: *missing\n"
        let workflow = WorkflowParser.parse(source)
        let diagnostic = try #require(
            workflow.diagnostics.first { $0.code == .invalidYAML }
        )
        #expect(diagnostic.line != nil)
    }

    @Test("Diagnostic identities are unique even when messages truncate")
    func uniqueDiagnosticIDs() {
        let prefix = String(repeating: "a", count: 60)
        let needs = (0..<60)
            .map { "\(prefix)\($0)" }
            .joined(separator: ", ")
        let source = "on: push\njobs:\n  build:\n    runs-on: x\n"
            + "    needs: [\(needs)]\n"
        let workflow = WorkflowParser.parse(source)
        let ids = workflow.diagnostics.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("An empty job id is reported and skipped")
    func emptyJobIdentifier() throws {
        let source = "on: push\njobs:\n  \"\":\n    runs-on: x\n"
            + "  build:\n    runs-on: x\n"
        let workflow = WorkflowParser.parse(source)
        #expect(workflow.jobs.map(\.id) == ["build"])
        let diagnostic = try #require(
            workflow.diagnostics.first { $0.code == .invalidJob }
        )
        #expect(diagnostic.line == 3)
    }

    @Test("An aliased needs list is reported at the needs key")
    func aliasedNeeds() throws {
        let source = """
            on: push
            shared: &n [missing]
            jobs:
              build:
                needs: *n
                runs-on: x
            """
        let workflow = WorkflowParser.parse(source)
        let diagnostic = try #require(
            workflow.diagnostics.first { $0.code == .unknownNeed }
        )
        #expect(diagnostic.line == 5)
    }

    // MARK: - DOT

    @Test("The chart carries one node per job and one edge per need")
    func dotEdges() throws {
        let workflow = WorkflowParser.parse(fixture)
        let dot = WorkflowDOT.render(workflow)
        #expect(dot.hasPrefix("digraph workflow {"))
        #expect(dot.contains("\"j0\" [label="))
        #expect(dot.contains("\"j1\" [label="))
        #expect(dot.contains("\"j2\" [label="))
        #expect(dot.contains("build"))
        #expect(dot.contains("test"))
        #expect(dot.contains("package"))
        #expect(dot.contains("\"j0\" -> \"j1\";"))
        #expect(dot.contains("\"j0\" -> \"j2\";"))
        #expect(dot.contains("\"j1\" -> \"j2\";"))
        #expect(dot.contains("missing") == false)
        #expect(dot.contains("label=\"CI\";"))
        #expect(GraphvizDiagramPolicy.accepts(dot))
    }

    @Test("Error jobs and quoted names are escaped for DOT")
    func dotEscaping() {
        let source = """
            on: push
            jobs:
              'a"b':
                runs-on: x
                needs: [missing]
            """
        let workflow = WorkflowParser.parse(source)
        let dot = WorkflowDOT.render(workflow)
        #expect(dot.contains("\"j0\" [label="))
        #expect(dot.contains("a&quot;b"))
        #expect(dot.contains("missing"))
        #expect(dot.contains("style=\"rounded,dashed,filled\""))
        #expect(dot.contains("\"m0\" -> \"j0\""))
        #expect(dot.contains("color=\"#C0392B\""))
        #expect(GraphvizDiagramPolicy.accepts(dot))
    }

    @Test("Grapheme and backslash labels are escaped as scalars")
    func dotScalarEscaping() {
        let source = """
            on: push
            jobs:
              build:
                name: "<\u{301}"
                runs-on: x
                steps:
                  - run: echo
            """
        let workflow = WorkflowParser.parse(source)
        let dot = WorkflowDOT.render(workflow)
        // The combining mark joins the semicolon into one grapheme, so the
        // assertion includes it; the raw '<' must be gone.
        #expect(dot.contains("&lt;\u{301}"))
        #expect(!dot.contains("name: <"))

        let backslash = WorkflowParser.parse(
            "on: push\njobs:\n  build:\n    name: '\\N'\n"
                + "    runs-on: x\n"
        )
        let backslashDOT = WorkflowDOT.render(backslash)
        #expect(backslashDOT.contains("\\\\N"))
    }

    @Test("XML-invalid controls are replaced in labels")
    func dotControlCharacters() {
        let source = "on: push\njobs:\n  build:\n    name: \"A\\x01B\"\n"
            + "    runs-on: x\n"
        let workflow = WorkflowParser.parse(source)
        let dot = WorkflowDOT.render(workflow)
        #expect(!dot.unicodeScalars.contains { $0.value == 0x01 })
        #expect(dot.contains("\u{FFFD}"))
    }

    @Test("A need outside the chart cap is not a ghost")
    func truncatedJobIsNotMissing() async throws {
        var source = "on: push\njobs:\n  job0:\n    runs-on: x\n"
            + "    needs: [job\(WorkflowDetection.maxJobs)]\n"
        for index in 1...WorkflowDetection.maxJobs {
            source += "  job\(index):\n    runs-on: x\n"
        }
        let workflow = WorkflowParser.parse(source)
        #expect(
            workflow.definedJobIDs.count == WorkflowDetection.maxJobs + 1
        )
        let dot = WorkflowDOT.render(workflow)
        #expect(!dot.contains("style=\"rounded,dashed,filled\""))
        #expect(!dot.contains("missing"))
    }

    @Test("A dense needs graph is rejected by the DOT cap")
    func denseNeedsExceedDOT() {
        var source = "on: push\njobs:\n"
        for index in 0..<WorkflowDetection.maxJobs {
            var needs: [String] = []
            for back in 1...20 where index - back >= 0 {
                needs.append("job\(index - back)")
            }
            source += "  job\(index):\n    runs-on: x\n"
            if !needs.isEmpty {
                source += "    needs: [\(needs.joined(separator: ", "))]\n"
            }
        }
        let workflow = WorkflowParser.parse(source)
        #expect(workflow.jobs.count == WorkflowDetection.maxJobs)
        let dot = WorkflowDOT.render(workflow)
        #expect(dot.count > MarkdownLimits.maxGraphvizSourceCharacters)
        #expect(!GraphvizDiagramPolicy.accepts(dot))
        #expect(WorkflowDiagramPolicy.dot(from: source) == nil)
    }

    @Test("The two palettes produce different explicit colors")
    func dotPalette() {
        let workflow = WorkflowParser.parse(fixture)
        let light = WorkflowDOT.render(workflow, variant: .light)
        let dark = WorkflowDOT.render(workflow, variant: .dark)
        #expect(light != dark)
        #expect(light.contains("fillcolor=\"#FAFAFB\""))
        #expect(light.contains("COLOR=\"#1F2328\""))
        #expect(light.contains("fontcolor=\"#1F2328\""))
        #expect(dark.contains("fillcolor=\"#1C1D20\""))
        #expect(dark.contains("COLOR=\"#E6E6E6\""))
        #expect(dark.contains("fontcolor=\"#E6E6E6\""))
    }

    @Test("Unknown needs are ghost nodes and cycle edges are dashed")
    func dotGhostsAndCycles() {
        let source = """
            on: push
            jobs:
              a:
                needs: [b, missing]
              b:
                needs: [a]
            """
        let workflow = WorkflowParser.parse(source)
        let dot = WorkflowDOT.render(workflow)
        #expect(dot.contains("\"m0\""))
        #expect(dot.contains("missing"))
        #expect(dot.contains("style=\"rounded,dashed,filled\""))
        #expect(
            dot.contains(
                "\"j1\" -> \"j0\" [color=\"#C0392B\", style=dashed"
            )
        )
        #expect(
            dot.contains(
                "\"j0\" -> \"j1\" [color=\"#C0392B\", style=dashed"
            )
        )
        #expect(GraphvizDiagramPolicy.accepts(dot))
    }

    @Test("A very long job id cannot push the DOT past its cap")
    func longIdentifier() {
        let id = String(repeating: "a", count: 900)
        let source = "on: push\njobs:\n  \(id):\n    runs-on: x\n"
        let workflow = WorkflowParser.parse(source)
        #expect(workflow.jobs.map(\.id) == [id])
        let dot = WorkflowDOT.render(workflow)
        #expect(dot.count < MarkdownLimits.maxGraphvizSourceCharacters)
        #expect(GraphvizDiagramPolicy.accepts(dot))
    }

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
