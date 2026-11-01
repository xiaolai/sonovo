import Foundation
import Yams

/// Reads a GitHub Actions workflow into the chart model.
///
/// Parsing never throws: every failure is reported as a diagnostic, and a
/// document that cannot be read still yields an empty chart the caller can
/// replace with the original YAML.
public enum WorkflowParser {
    public static func parse(_ source: String) -> Workflow {
        var diagnostics: [WorkflowDiagnostic] = []
        guard WorkflowDetection.acceptsSource(source) else {
            let code: WorkflowDiagnosticCode
            let message: String
            if source.utf8.count > WorkflowDetection.maxSourceBytes {
                code = .sourceTooLarge
                message = "The workflow is larger than 256 KB."
            } else if source.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
                code = .emptyDocument
                message = "The workflow is empty."
            } else {
                code = .unreadableSource
                message = "The workflow contains a NUL byte."
            }
            diagnostics.append(
                WorkflowDiagnostic(
                    code: code,
                    severity: .error,
                    message: message
                )
            )
            return finalized(name: nil, diagnostics: diagnostics)
        }

        let root: Node
        do {
            guard let composed = try Yams.compose(yaml: source) else {
                diagnostics.append(
                    WorkflowDiagnostic(
                        code: .emptyDocument,
                        severity: .error,
                        message: "The workflow is empty."
                    )
                )
                return finalized(name: nil, diagnostics: diagnostics)
            }
            root = composed
        } catch {
            if case let YamlError.duplicatedKeysInMapping(duplicates, _) =
                error {
                // Yams refuses the document, and so does GitHub. Name the
                // keys instead of reporting an opaque parse failure.
                let list = duplicates.prefix(3)
                    .map(display)
                    .joined(separator: ", ")
                // Yams reports the mark of the first occurrence, not the
                // duplicate, so no line is underlined: pointing at the valid
                // key would be worse than pointing nowhere.
                diagnostics.append(
                    WorkflowDiagnostic(
                        code: .duplicateKey,
                        severity: .error,
                        message: "Duplicate keys in the YAML: \(list). "
                            + "GitHub rejects duplicate keys."
                    )
                )
            } else {
                diagnostics.append(
                    WorkflowDiagnostic(
                        code: .invalidYAML,
                        severity: .error,
                        message: "The file is not valid YAML: "
                            + shortDescription(of: error),
                        line: markLine(of: error)
                    )
                )
            }
            return finalized(name: nil, diagnostics: diagnostics)
        }

        guard let document = root.mapping else {
            diagnostics.append(
                WorkflowDiagnostic(
                    code: .notAMapping,
                    severity: .error,
                    message: "A workflow must be a YAML mapping."
                )
            )
            return finalized(name: nil, diagnostics: diagnostics)
        }

        let name = document["name"]?.string.flatMap { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : value
        }

        guard let jobsNode = document["jobs"] else {
            diagnostics.append(
                WorkflowDiagnostic(
                    code: .missingJobs,
                    severity: .error,
                    message: "The workflow has no jobs: key."
                )
            )
            return finalized(name: name, diagnostics: diagnostics)
        }
        guard let jobsMapping = jobsNode.mapping else {
            diagnostics.append(
                WorkflowDiagnostic(
                    code: .jobsNotAMapping,
                    severity: .error,
                    message: "jobs: must be a mapping of job identifiers.",
                    line: jobsNode.mark?.line
                )
            )
            return finalized(name: name, diagnostics: diagnostics)
        }

        var jobs: [WorkflowJob] = []
        var needLines: [String: [Int?]] = [:]
        var definedIDs: Set<String> = []
        var limitReported = false

        for (keyNode, valueNode) in jobsMapping {
            guard case .scalar = keyNode, let id = keyNode.string else {
                diagnostics.append(
                    WorkflowDiagnostic(
                        code: .invalidJob,
                        severity: .error,
                        message: "A job identifier must be a scalar.",
                        line: keyNode.mark?.line
                    )
                )
                continue
            }
            guard !id.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                diagnostics.append(
                    WorkflowDiagnostic(
                        code: .invalidJob,
                        severity: .error,
                        message: "A job has an empty identifier.",
                        line: keyNode.mark?.line
                    )
                )
                continue
            }
            // Keys with different YAML tags can share the same text. The
            // chart is keyed by that text, so treat the second as a
            // duplicate instead of silently replacing the first.
            if definedIDs.contains(id) {
                diagnostics.append(
                    WorkflowDiagnostic(
                        code: .duplicateKey,
                        severity: .error,
                        message: "Job “\(display(id))” appears more than "
                            + "once with different YAML values.",
                        jobIDs: [id],
                        line: keyNode.mark?.line
                    )
                )
                continue
            }
            // Every defined id counts for unknown-need checking, including
            // jobs truncated from the chart: a need that resolves to a real
            // job is not an error just because the chart dropped its node.
            definedIDs.insert(id)
            if jobs.count >= WorkflowDetection.maxJobs {
                if !limitReported {
                    limitReported = true
                    diagnostics.append(
                        WorkflowDiagnostic(
                            code: .jobLimit,
                            severity: .warning,
                            message: "Only the first "
                                + "\(WorkflowDetection.maxJobs) jobs are "
                                + "shown."
                        )
                    )
                }
                continue
            }
            let parsed = parseJob(
                id: id,
                node: valueNode,
                line: keyNode.mark?.line,
                diagnostics: &diagnostics
            )
            jobs.append(parsed.job)
            needLines[id] = parsed.needLines
        }

        appendUnknownNeeds(
            jobs: jobs,
            definedIDs: definedIDs,
            needLines: needLines,
            diagnostics: &diagnostics
        )
        appendCycles(jobs: jobs, diagnostics: &diagnostics)

        return finalized(name: name, jobs: jobs, diagnostics: diagnostics, definedJobIDs: definedIDs)
    }

    // MARK: - Jobs

    private struct ParsedJob {
        let job: WorkflowJob
        /// The source line of each need, aligned with `job.needs`.
        let needLines: [Int?]
    }

    private static func parseJob(
        id: String,
        node: Node,
        line: Int?,
        diagnostics: inout [WorkflowDiagnostic]
    ) -> ParsedJob {
        guard let mapping = node.mapping else {
            diagnostics.append(
                WorkflowDiagnostic(
                    code: .invalidJob,
                    severity: .error,
                    message: "Job “\(display(id))” is not a mapping.",
                    jobIDs: [id],
                    line: line
                )
            )
            return ParsedJob(
                job: WorkflowJob(
                    id: id,
                    name: nil,
                    runsOn: [],
                    needs: [],
                    stepCount: 0,
                    uses: nil,
                    matrixKeys: [],
                    line: line
                ),
                needLines: []
            )
        }

        let name = mapping["name"]?.string
        let runsOn = strings(in: mapping["runs-on"])
        // An aliased needs: list carries the anchor definition's marks, not
        // the use site's. Clamp every need line to the key's own line so the
        // underline cannot land on an unrelated earlier anchor.
        let needsKeyLine = mapping.first { pair in
            pair.key.string == "needs"
        }?.key.mark?.line
        let (needs, needLines) = uniqueNeeds(
            in: mapping["needs"],
            minimumLine: needsKeyLine,
            fallbackLine: line,
            jobID: id,
            diagnostics: &diagnostics
        )
        let stepCount = mapping["steps"]?.sequence?.count ?? 0
        let uses = mapping["uses"]?.string
        let matrixKeys = matrixKeys(in: mapping["strategy"])

        return ParsedJob(
            job: WorkflowJob(
                id: id,
                name: name,
                runsOn: runsOn,
                needs: needs,
                stepCount: stepCount,
                uses: uses,
                matrixKeys: matrixKeys,
                line: line
            ),
            needLines: needLines
        )
    }

    private static func strings(in node: Node?) -> [String] {
        guard let node else { return [] }
        if let scalar = node.string {
            let trimmed = scalar.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return trimmed.isEmpty ? [] : [trimmed]
        }
        guard let sequence = node.sequence else { return [] }
        return sequence.compactMap { element in
            guard let value = element.string else { return nil }
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func uniqueNeeds(
        in node: Node?,
        minimumLine: Int?,
        fallbackLine: Int?,
        jobID: String,
        diagnostics: inout [WorkflowDiagnostic]
    ) -> (values: [String], lines: [Int?]) {
        guard let node else { return ([], []) }
        var values: [String] = []
        var lines: [Int?] = []
        var seen: Set<String> = []
        func append(_ value: String, line: Int?) {
            guard !value.isEmpty, !seen.contains(value) else { return }
            seen.insert(value)
            values.append(value)
            lines.append(line)
        }
        func sourceLine(of element: Node) -> Int? {
            guard let elementLine = element.mark?.line else {
                return minimumLine ?? fallbackLine
            }
            guard let minimumLine else { return elementLine }
            return max(elementLine, minimumLine)
        }
        var reportedInvalid = false
        func reportInvalid(_ message: String, line: Int?) {
            guard !reportedInvalid else { return }
            reportedInvalid = true
            diagnostics.append(
                WorkflowDiagnostic(
                    code: .invalidNeeds,
                    severity: .error,
                    message: "Job “\(display(jobID))” \(message)",
                    jobIDs: [jobID],
                    line: line ?? minimumLine ?? fallbackLine
                )
            )
        }
        if case .scalar = node, let scalar = node.string {
            append(
                scalar.trimmingCharacters(in: .whitespacesAndNewlines),
                line: sourceLine(of: node)
            )
        } else if case .sequence = node, let sequence = node.sequence {
            for element in sequence {
                guard case .scalar = element,
                      let value = element.string else {
                    reportInvalid(
                        "has a needs entry that is not a job name.",
                        line: sourceLine(of: element)
                    )
                    continue
                }
                append(
                    value.trimmingCharacters(in: .whitespacesAndNewlines),
                    line: sourceLine(of: element)
                )
            }
        } else {
            reportInvalid(
                "has a needs: value that is not a job name or a list "
                    + "of names.",
                line: minimumLine ?? fallbackLine
            )
        }
        return (values, lines)
    }

    private static func matrixKeys(in strategy: Node?) -> [String] {
        guard let matrix = strategy?.mapping?["matrix"]?.mapping else {
            return []
        }
        return matrix.compactMap { key, _ in
            guard let value = key.string else { return nil }
            return value == "include" || value == "exclude" ? nil : value
        }
    }

    // MARK: - Diagnostics

    /// One diagnostic per unknown need, capped so a pathological document
    /// cannot build an unbounded list (and an unbounded tooltip or underline
    /// set) from one parse.
    static let maxUnknownNeedDiagnostics = 50

    private static func appendUnknownNeeds(
        jobs: [WorkflowJob],
        definedIDs: Set<String>,
        needLines: [String: [Int?]],
        diagnostics: inout [WorkflowDiagnostic]
    ) {
        var reported = 0
        var suppressed = 0
        for job in jobs {
            let lines = needLines[job.id] ?? []
            for (index, need) in job.needs.enumerated()
            where !definedIDs.contains(need) {
                guard reported < maxUnknownNeedDiagnostics else {
                    suppressed += 1
                    continue
                }
                let line = index < lines.count
                    ? (lines[index] ?? job.line)
                    : job.line
                diagnostics.append(
                    WorkflowDiagnostic(
                        code: .unknownNeed,
                        severity: .error,
                        message: "Job “\(display(job.id))” needs "
                            + "“\(display(need))”, which is not defined.",
                        jobIDs: [job.id],
                        line: line
                    )
                )
                reported += 1
            }
        }
        if suppressed > 0 {
            diagnostics.append(
                WorkflowDiagnostic(
                    code: .diagnosticLimit,
                    severity: .warning,
                    message: "\(suppressed) more unknown need"
                        + (suppressed == 1 ? " is" : "s are")
                        + " not listed."
                )
            )
        }
    }

    private static func appendCycles(
        jobs: [WorkflowJob],
        diagnostics: inout [WorkflowDiagnostic]
    ) {
        for cycle in dependencyCycles(in: jobs) {
            let members = cycle.map(display)
            let path = members.count <= 6
                ? (members + [members[0]]).joined(separator: " → ")
                : members.prefix(6).joined(separator: " → ")
                    + " → … (\(members.count) jobs)"
            diagnostics.append(
                WorkflowDiagnostic(
                    code: .dependencyCycle,
                    severity: .error,
                    message: "Dependency cycle: \(path).",
                    jobIDs: cycle,
                    line: jobs.first { $0.id == cycle[0] }?.line
                )
            )
        }
    }

    /// Returns one cycle per back edge, in document order of its first
    /// member. This finds at least one ring in every cyclic component; it
    /// does not enumerate every simple cycle in a dense ring. Edges to
    /// unknown jobs are ignored: they are an unknown-need error, not part of
    /// a ring.
    private static func dependencyCycles(
        in jobs: [WorkflowJob]
    ) -> [[String]] {
        let known = Set(jobs.map(\.id))
        var adjacency: [String: [String]] = [:]
        for job in jobs {
            adjacency[job.id] = job.needs.filter { known.contains($0) }
        }

        var state: [String: Int] = [:]
        var stack: [String] = []
        var seenKeys: Set<String> = []
        var cycles: [[String]] = []

        func canonicalKey(_ cycle: [String]) -> String {
            guard let smallest = cycle.indices.min(by: {
                cycle[$0] < cycle[$1]
            }) else { return "" }
            let rotated = Array(cycle[smallest...])
                + Array(cycle[..<smallest])
            return rotated.joined(separator: "\u{1F}")
        }

        func visit(_ id: String) {
            state[id] = 1
            stack.append(id)
            for next in adjacency[id] ?? [] {
                switch state[next] ?? 0 {
                case 0:
                    visit(next)
                case 1:
                    guard let start = stack.firstIndex(of: next) else {
                        continue
                    }
                    let cycle = Array(stack[start...])
                    let key = canonicalKey(cycle)
                    if seenKeys.insert(key).inserted {
                        cycles.append(cycle)
                    }
                default:
                    continue
                }
            }
            stack.removeLast()
            state[id] = 2
        }

        for job in jobs where (state[job.id] ?? 0) == 0 {
            visit(job.id)
        }
        return cycles.sorted { lhs, rhs in
            let lhsLine = jobs.first { $0.id == lhs[0] }?.line ?? .max
            let rhsLine = jobs.first { $0.id == rhs[0] }?.line ?? .max
            return lhsLine < rhsLine
        }
    }

    private static func finalized(
        name: String?,
        jobs: [WorkflowJob] = [],
        diagnostics: [WorkflowDiagnostic],
        definedJobIDs: Set<String> = []
    ) -> Workflow {
        let identified = diagnostics.enumerated().map { index, diagnostic in
            diagnostic.withID(
                "\(diagnostic.code.rawValue)-\(index)"
            )
        }
        return Workflow(
            name: name,
            jobs: jobs,
            diagnostics: identified,
            definedJobIDs: definedJobIDs
        )
    }

    /// The line Yams reported for a scanner, parser, or composer failure.
    private static func markLine(of error: Error) -> Int? {
        switch error {
        case let YamlError.scanner(_, _, mark, _):
            return mark.line
        case let YamlError.parser(_, _, mark, _):
            return mark.line
        case let YamlError.composer(_, _, mark, _):
            return mark.line
        default:
            return nil
        }
    }

    private static let identifierLimit = 48

    private static func display(_ identifier: String) -> String {
        identifier.count <= identifierLimit
            ? identifier
            : String(identifier.prefix(identifierLimit)) + "…"
    }

    private static func shortDescription(of error: Error) -> String {
        let text = String(describing: error)
            .replacingOccurrences(of: "\n", with: " ")
        return text.count > 200
            ? String(text.prefix(200)) + "…"
            : text
    }
}
