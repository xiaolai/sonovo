import Foundation

/// Why a parse produced no tree. The last successful output survives a
/// refusal; the reason is additional state, not a replacement.
public enum MarkdownParseRefusal: String, Sendable, Equatable {
    /// The source exceeded the container-nesting or inline-nesting bound and
    /// was kept as one raw block.
    case nestingLimit
}

/// The document-owned parse state. Every consumer reads this; none starts its
/// own parse task.
public enum MarkdownParseState: Sendable {
    case idle
    case parsing(revision: UInt64)
    case ready(MarkdownParseOutput)
    case refused(MarkdownParseRefusal, revision: UInt64)

    /// The revision this state describes, when it describes one.
    public var revision: UInt64? {
        switch self {
        case .idle:
            return nil
        case .parsing(let revision):
            return revision
        case .ready(let output):
            return output.revision
        case .refused(_, let revision):
            return revision
        }
    }

    public var isParsing: Bool {
        if case .parsing = self { return true }
        return false
    }
}
