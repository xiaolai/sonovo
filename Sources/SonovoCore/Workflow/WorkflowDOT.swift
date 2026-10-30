import Foundation

/// Turns a workflow into Graphviz DOT for the existing diagram renderer.
///
/// The chart uses HTML-like labels: each job is a small card with a bold
/// display name, a muted id when it differs, and one muted metadata line.
/// The DOT is generated per palette, so fills, borders, and ink are explicit
/// rather than relying on the renderer's black-to-light restyle. Unknown
/// needs become dashed ghost nodes; cycle edges are dashed in the error
/// color.
public enum WorkflowDOT {
    public static func render(
        _ workflow: Workflow,
        variant: DiagramThemeVariant = .light
    ) -> String {
        let palette = Palette(variant: variant)
        let problemJobs = workflow.problemJobIDs
        let known = Set(workflow.jobs.map(\.id))
        let defined = workflow.effectiveDefinedJobIDs
        let cycleEdges = cycleEdgeKeys(workflow)
        let ghosts = ghostNodes(
            workflow: workflow,
            defined: defined,
            limit: 50
        )

        var lines: [String] = ["digraph workflow {"]
        lines.append(
            "  graph [rankdir=LR, nodesep=0.45, ranksep=0.8, "
                + "pad=0.25, splines=spline, outputorder=edgesfirst, "
                + "bgcolor=\"transparent\"];"
        )
        if let name = workflow.name, !name.isEmpty {
            lines.append("  label=\(quote(truncated(name, limit: 60)));")
            lines.append("  labelloc=t;")
            lines.append("  labeljust=l;")
            lines.append("  fontsize=12;")
            lines.append("  fontcolor=\(quote(palette.ink));")
            lines.append("  fontname=\"Helvetica\";")
        }
        lines.append(
            "  node [shape=box, style=\"rounded,filled\", "
                + "fillcolor=\(quote(palette.nodeFill)), "
                + "color=\(quote(palette.nodeBorder)), "
                + "penwidth=1.2, margin=\"0.16,0.10\", "
                + "fontname=\"Helvetica\", fontsize=12];"
        )
        lines.append(
            "  edge [color=\(quote(palette.edge)), penwidth=1.1, "
                + "arrowsize=0.65];"
        )

        // Node names are positional, not the job ids. A job id is arbitrary
        // text and can be long; keeping it in the label alone bounds the DOT
        // by the job count instead of by identifier length.
        var nodeNameByID: [String: String] = [:]
        for (index, job) in workflow.jobs.enumerated() {
            nodeNameByID[job.id] = "j\(index)"
        }

        for (index, job) in workflow.jobs.enumerated() {
            let isProblem = problemJobs.contains(job.id)
            let fill = isProblem ? palette.errorFill : palette.nodeFill
            let border = isProblem ? palette.errorBorder : palette.nodeBorder
            lines.append(
                "  \"j\(index)\" [label=\(htmlLabel(job, palette: palette)), "
                    + "fillcolor=\(quote(fill)), color=\(quote(border))];"
            )
        }

        for ghost in ghosts {
            lines.append(
                "  \(quote(ghost.nodeName)) [label="
                    + "\(ghostLabel(ghost.need, palette: palette)), "
                    + "style=\"rounded,dashed,filled\", "
                    + "fillcolor=\(quote(palette.ghostFill)), "
                    + "color=\(quote(palette.ghostBorder))];"
            )
        }

        for (index, job) in workflow.jobs.enumerated() {
            for need in job.needs {
                guard known.contains(need),
                      let needNode = nodeNameByID[need] else {
                    continue
                }
                let attributes: String
                if cycleEdges.contains(edgeKey(need, job.id)) {
                    attributes = " [color=\(quote(palette.errorBorder)), "
                        + "style=dashed, penwidth=1.3]"
                } else {
                    attributes = ""
                }
                lines.append(
                    "  \(quote(needNode)) -> \"j\(index)\"\(attributes);"
                )
            }
        }

        for ghost in ghosts {
            for jobID in ghost.dependentJobIDs {
                guard let job = workflow.jobs.first(where: {
                    $0.id == jobID
                }), let jobNode = nodeNameByID[job.id] else {
                    continue
                }
                lines.append(
                    "  \(quote(ghost.nodeName)) -> \(quote(jobNode)) "
                        + "[color=\(quote(palette.errorBorder)), "
                        + "style=dashed, penwidth=1.1];"
                )
            }
        }

        if workflow.jobs.isEmpty {
            lines.append("  empty [label=\"No jobs\", shape=note];")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    // MARK: - Nodes

    private static func htmlLabel(
        _ job: WorkflowJob,
        palette: Palette
    ) -> String {
        var rows: [String] = []
        let title: String
        if let name = job.name, !name.isEmpty, name != job.id {
            title = truncated(name, limit: 32)
        } else {
            title = truncated(job.id, limit: 32)
        }
        rows.append(
            row(
                title,
                size: "13",
                color: palette.ink,
                bold: true
            )
        )
        // One secondary row, not two: name and metadata share it, so every
        // card has the same height and the ranks line up.
        var secondary: [String] = []
        if let name = job.name, !name.isEmpty, name != job.id {
            secondary.append(truncated(job.id, limit: 36))
        }
        if let metadata = metadata(for: job) {
            secondary.append(metadata)
        }
        if !secondary.isEmpty {
            rows.append(
                row(
                    truncated(secondary.joined(separator: " · "), limit: 46),
                    size: "9.5",
                    color: palette.muted
                )
            )
        }
        return "<" + table(rows) + ">"
    }

    private static func ghostLabel(
        _ need: String,
        palette: Palette
    ) -> String {
        let rows = [
            row("missing", size: "9.5", color: palette.muted),
            row(
                truncated(need, limit: 34),
                size: "11",
                color: palette.errorInk,
                bold: true
            )
        ]
        return "<" + table(rows) + ">"
    }

    private static func row(
        _ text: String,
        size: String,
        color: String,
        bold: Bool = false
    ) -> String {
        let body = bold ? "<B>\(escapeHTML(text))</B>" : escapeHTML(text)
        return "<TR><TD ALIGN=\"LEFT\"><FONT POINT-SIZE=\"\(size)\" "
            + "COLOR=\(quote(color))>\(body)</FONT></TD></TR>"
    }

    private static func table(_ rows: [String]) -> String {
        "<TABLE BORDER=\"0\" CELLBORDER=\"0\" CELLSPACING=\"0\" "
            + "CELLPADDING=\"1\">"
            + rows.joined()
            + "</TABLE>"
    }

    private static func metadata(for job: WorkflowJob) -> String? {
        if let uses = job.uses, !uses.isEmpty {
            return truncated("reusable · " + uses, limit: 42)
        }
        var parts: [String] = []
        if !job.runsOn.isEmpty {
            parts.append(job.runsOn.joined(separator: ", "))
        }
        if job.stepCount > 0 {
            parts.append(
                "\(job.stepCount) step" + (job.stepCount == 1 ? "" : "s")
            )
        }
        if !job.matrixKeys.isEmpty {
            parts.append(
                "matrix: " + job.matrixKeys.joined(separator: ", ")
            )
        }
        guard !parts.isEmpty else { return nil }
        return truncated(parts.joined(separator: " · "), limit: 42)
    }

    private struct Ghost {
        let nodeName: String
        let need: String
        let dependentJobIDs: [String]
    }

    private static func ghostNodes(
        workflow: Workflow,
        defined: Set<String>,
        limit: Int
    ) -> [Ghost] {
        var order: [String] = []
        var dependents: [String: [String]] = [:]
        for job in workflow.jobs {
            for need in job.needs where !defined.contains(need) {
                if dependents[need] == nil {
                    guard order.count < limit else { continue }
                    order.append(need)
                    dependents[need] = []
                }
                if !(dependents[need]?.contains(job.id) ?? false) {
                    dependents[need]?.append(job.id)
                }
            }
        }
        return order.enumerated().map { index, need in
            Ghost(
                nodeName: "m\(index)",
                need: need,
                dependentJobIDs: dependents[need] ?? []
            )
        }
    }

    private static func cycleEdgeKeys(_ workflow: Workflow) -> Set<String> {
        var result: Set<String> = []
        for diagnostic in workflow.diagnostics
        where diagnostic.code == .dependencyCycle {
            let cycle = diagnostic.jobIDs
            guard !cycle.isEmpty else { continue }
            for index in cycle.indices {
                let job = cycle[index]
                let dependency = cycle[(index + 1) % cycle.count]
                result.insert(edgeKey(dependency, job))
            }
        }
        return result
    }

    private static func edgeKey(_ dependency: String, _ job: String) -> String {
        dependency + "\u{1F}" + job
    }

    // MARK: - Text

    private static func truncated(_ value: String, limit: Int) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    private static func escapeHTML(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\\": result += "\\\\"
            default:
                appendPrintable(scalar, to: &result)
            }
        }
        return result
    }

    /// XML 1.0 forbids most C0 controls. A YAML escape can still produce
    /// one, and Graphviz rejects the label rather than drawing it.
    private static func appendPrintable(
        _ scalar: Unicode.Scalar,
        to result: inout String
    ) {
        if scalar.value < 0x20 || scalar.value == 0x7F {
            result.append("\u{FFFD}")
        } else {
            result.unicodeScalars.append(scalar)
        }
    }

    /// A DOT double-quoted string. A newline separates label rows, so it is
    /// emitted as the two-character DOT escape.
    private static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": break
            default:
                appendPrintable(scalar, to: &result)
            }
        }
        return result + "\""
    }

    // MARK: - Palette

    private struct Palette {
        let nodeFill: String
        let nodeBorder: String
        let ink: String
        let muted: String
        let edge: String
        let errorBorder: String
        let errorFill: String
        let errorInk: String
        let ghostFill: String
        let ghostBorder: String

        init(variant: DiagramThemeVariant) {
            switch variant {
            case .light:
                nodeFill = "#FAFAFB"
                nodeBorder = "#D8DBE0"
                ink = "#1F2328"
                muted = "#6B7280"
                edge = "#A0A6AD"
                errorBorder = "#C0392B"
                errorFill = "#FDF2F2"
                errorInk = "#B42318"
                ghostFill = "#F3F4F6"
                ghostBorder = "#9CA3AF"
            case .dark:
                nodeFill = "#1C1D20"
                nodeBorder = "#3A3D42"
                ink = "#E6E6E6"
                muted = "#9AA0A6"
                edge = "#5F656D"
                errorBorder = "#E06C61"
                errorFill = "#2A1D1D"
                errorInk = "#F1998E"
                ghostFill = "#202124"
                ghostBorder = "#5F656D"
            }
        }
    }
}
