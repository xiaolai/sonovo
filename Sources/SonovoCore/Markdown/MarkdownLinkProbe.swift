import Foundation

public enum MarkdownProbeOutcome: String, Sendable, Equatable {
    case exists
    case missing
    /// Outside the project, on a non-local mount, or over the probe budget.
    case notChecked
}

/// Checks local link and image destinations without leaving the project.
///
/// The service dedupes destinations, caps how many it probes and how long it
/// spends, and classifies anything it cannot safely prove as `notChecked`
/// rather than `missing`.
public actor MarkdownLinkProbeService {
    public typealias Exists = @Sendable (URL) -> Bool

    private let exists: Exists
    private let maximumPaths: Int
    private let deadline: TimeInterval

    public init(
        maximumPaths: Int = 256,
        deadline: TimeInterval = 2.0,
        exists: @escaping Exists = { url in
            FileManager.default.fileExists(atPath: url.path)
        }
    ) {
        self.maximumPaths = max(1, maximumPaths)
        self.deadline = max(0, deadline)
        self.exists = exists
    }

    public func check(
        destinations: [String],
        documentURL: URL?,
        root: URL?
    ) async -> [String: MarkdownProbeOutcome] {
        var outcomes: [String: MarkdownProbeOutcome] = [:]
        var unique: [String] = []
        for destination in destinations where outcomes[destination] == nil {
            guard unique.count < maximumPaths else {
                outcomes[destination] = .notChecked
                continue
            }
            unique.append(destination)
        }

        let resolver = MarkdownPathResolver(
            documentURL: documentURL,
            root: root,
            exists: MarkdownPathResolver.liveExists,
            canonicalize: MarkdownPathResolver.liveCanonical,
            isLocalMount: MarkdownPathResolver.liveIsLocalMount
        )
        let start = Date()
        for destination in unique {
            if Task.isCancelled { break }
            if Date().timeIntervalSince(start) > deadline {
                outcomes[destination] = .notChecked
                continue
            }
            switch resolver.resolve(destination) {
            case .resolved(let url):
                outcomes[destination] = exists(url) ? .exists : .missing
            case .missing:
                outcomes[destination] = .missing
            case .refused, .ambiguous:
                outcomes[destination] = .notChecked
            }
        }
        return outcomes
    }
}

public extension MarkdownLintEngine {
    struct ProbeTarget: Sendable, Equatable {
        public let destination: String
        public let range: Range<Int>
        public let isImage: Bool
    }

    /// Local destinations that the probe service may check. Remote schemes
    /// and fragments are skipped here; the engine never probes them.
    static func probeTargets(ast: SonovoAST) -> [ProbeTarget] {
        var targets: [ProbeTarget] = []
        walkInlines(ast.blocks) { inline in
            switch inline {
            case .link(let destination, _, _, let range):
                guard let range, isLocalCandidate(destination) else { return }
                targets.append(
                    ProbeTarget(
                        destination: destination,
                        range: range.lowerBound..<range.upperBound,
                        isImage: false
                    )
                )
            case .image(let destination, _, _, let range):
                guard let range, isLocalCandidate(destination) else { return }
                targets.append(
                    ProbeTarget(
                        destination: destination,
                        range: range.lowerBound..<range.upperBound,
                        isImage: true
                    )
                )
            default:
                break
            }
        }
        return targets
    }

    /// Appends M001 (missing link target) and M002 (missing image target).
    /// `notChecked` stays silent: it is not evidence of a defect.
    static func appendingProbeResults(
        _ outcomes: [String: MarkdownProbeOutcome],
        targets: [ProbeTarget],
        to result: MarkdownLintResult
    ) -> MarkdownLintResult {
        var diagnostics = result.diagnostics
        for target in targets {
            guard outcomes[target.destination] == .missing else { continue }
            diagnostics.append(
                MarkdownDiagnostic(
                    ruleID: target.isImage ? "M002" : "M001",
                    severity: .warning,
                    range: target.range,
                    message: target.isImage
                        ? "Image file not found: \(target.destination)"
                        : "Link target not found: \(target.destination)"
                )
            )
        }
        diagnostics.sort {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.ruleID < $1.ruleID
        }
        return MarkdownLintResult(
            documentID: result.documentID,
            revision: result.revision,
            diagnostics: diagnostics
        )
    }

    private static func isLocalCandidate(_ destination: String) -> Bool {
        let trimmed = destination
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }
        if let url = URL(string: trimmed), url.scheme != nil {
            return false
        }
        return true
    }
}
