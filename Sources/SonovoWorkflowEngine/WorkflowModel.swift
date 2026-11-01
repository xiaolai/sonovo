import Foundation

/// One job in a GitHub Actions workflow, reduced to what a chart shows.
public struct WorkflowJob: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String?
    public let runsOn: [String]
    public let needs: [String]
    public let stepCount: Int
    /// The `uses:` value of a reusable-workflow job. Such a job has no
    /// `runs-on` and no steps of its own.
    public let uses: String?
    public let matrixKeys: [String]
    /// The 1-based line of the job identifier in the source, when the
    /// parser recorded one.
    public let line: Int?

    public init(
        id: String,
        name: String?,
        runsOn: [String],
        needs: [String],
        stepCount: Int,
        uses: String?,
        matrixKeys: [String],
        line: Int?
    ) {
        self.id = id
        self.name = name
        self.runsOn = runsOn
        self.needs = needs
        self.stepCount = stepCount
        self.uses = uses
        self.matrixKeys = matrixKeys
        self.line = line
    }
}

/// The problems the workflow linter reports.
///
/// The values are stable identifiers: the code viewer shows them, and tests
/// assert on them instead of on message text.
public enum WorkflowDiagnosticCode: String, Equatable, Sendable {
    case sourceTooLarge = "source-too-large"
    case unreadableSource = "unreadable-source"
    case invalidYAML = "invalid-yaml"
    case emptyDocument = "empty-document"
    case notAMapping = "not-a-mapping"
    case missingJobs = "missing-jobs"
    case jobsNotAMapping = "jobs-not-a-mapping"
    case invalidJob = "invalid-job"
    case invalidNeeds = "invalid-needs"
    case duplicateKey = "duplicate-key"
    case unknownNeed = "unknown-need"
    case dependencyCycle = "dependency-cycle"
    case jobLimit = "job-limit"
    case diagnosticLimit = "diagnostic-limit"
}

/// One problem found while reading a workflow.
public struct WorkflowDiagnostic: Equatable, Sendable, Identifiable {
    public enum Severity: String, Equatable, Sendable {
        case error
        case warning
    }

    public let code: WorkflowDiagnosticCode
    public let severity: Severity
    public let message: String
    /// Every job the diagnostic is about. A cycle names all of its members
    /// so the chart can mark the whole ring.
    public let jobIDs: [String]
    /// The 1-based source line to underline, when one is known.
    public let line: Int?
    /// A stable identity for list rendering. The parser makes it unique per
    /// diagnostic; it must not depend on the truncated display message.
    public let id: String

    public init(
        code: WorkflowDiagnosticCode,
        severity: Severity,
        message: String,
        jobIDs: [String] = [],
        line: Int? = nil,
        id: String? = nil
    ) {
        self.code = code
        self.severity = severity
        self.message = message
        self.jobIDs = jobIDs
        self.line = line
        self.id = id ?? "\(code.rawValue)#\(line ?? 0)#\(message)"
    }

    func withID(_ id: String) -> WorkflowDiagnostic {
        WorkflowDiagnostic(
            code: code,
            severity: severity,
            message: message,
            jobIDs: jobIDs,
            line: line,
            id: id
        )
    }

    public var isError: Bool { severity == .error }
}

/// A parsed GitHub Actions workflow.
public struct Workflow: Equatable, Sendable {
    public let name: String?
    public let jobs: [WorkflowJob]
    public let diagnostics: [WorkflowDiagnostic]
    /// Every job id defined in the source, including jobs omitted from the
    /// chart by the job cap. A ghost node is only for a dependency that is
    /// not in this set.
    public let definedJobIDs: Set<String>

    public init(
        name: String?,
        jobs: [WorkflowJob],
        diagnostics: [WorkflowDiagnostic],
        definedJobIDs: Set<String> = []
    ) {
        self.name = name
        self.jobs = jobs
        self.diagnostics = diagnostics
        self.definedJobIDs = definedJobIDs
    }

    /// The defined ids to use for ghost detection. A workflow built without
    /// the set (a test fixture) falls back to its charted jobs.
    public var effectiveDefinedJobIDs: Set<String> {
        definedJobIDs.isEmpty ? Set(jobs.map(\.id)) : definedJobIDs
    }

    public var hasJobs: Bool { !jobs.isEmpty }

    public var errorCount: Int {
        diagnostics.reduce(0) { $0 + ($1.isError ? 1 : 0) }
    }

    /// Jobs an error names; the chart draws them in the error color.
    public var problemJobIDs: Set<String> {
        var result: Set<String> = []
        for diagnostic in diagnostics where diagnostic.isError {
            result.formUnion(diagnostic.jobIDs)
        }
        return result
    }
}
