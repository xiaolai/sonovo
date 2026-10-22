import Foundation

/// What the reviewer concluded about one frozen diff pair.
enum CodeReviewDisposition: String, CaseIterable, Codable, Sendable, Identifiable {
    case seen
    case changesRequested

    var id: String { rawValue }

    var label: String {
        switch self {
        case .seen: "Seen"
        case .changesRequested: "Changes requested"
        }
    }

    var instructionLabel: String {
        switch self {
        case .seen: "seen"
        case .changesRequested: "changes requested"
        }
    }
}

/// A decision about one exact before/after pair.
///
/// The hashes are the content identity: the same path at a later revision is
/// a different pair, so a decision can never silently apply to bytes it was
/// not made against.
struct CodeReviewDecision: Equatable, Sendable {
    let path: String
    let leftLabel: String
    let rightLabel: String
    let leftHash: String
    let rightHash: String
    let disposition: CodeReviewDisposition
    let note: String
    /// `path:line:column` at the moment of the decision.
    let reference: String
    let createdAt: Date

    var shortLeftHash: String { String(leftHash.prefix(7)) }
    var shortRightHash: String { String(rightHash.prefix(7)) }

    var pairSummary: String {
        "\(leftLabel) → \(rightLabel) "
            + "(\(shortLeftHash) → \(shortRightHash))"
    }
}

/// The text handed to a worker. The full form is copied; the one-line form is
/// the only shape that may reach a terminal, and it never carries a newline.
enum CodeReviewInstruction {
    static func text(for decision: CodeReviewDecision) -> String {
        var lines = [
            "Review of \(decision.path)",
            "Pair: \(decision.pairSummary)",
            "Decision: \(decision.disposition.instructionLabel)",
            "Reference: \(decision.reference)"
        ]
        let note = decision.note.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !note.isEmpty {
            lines.append("")
            lines.append(note)
        }
        return lines.joined(separator: "\n")
    }

    static func oneLine(for decision: CodeReviewDecision) -> String {
        let note = decision.note
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var line = "Review \(decision.path) (\(decision.pairSummary)): "
            + decision.disposition.instructionLabel
        if !note.isEmpty {
            line += " — \(note)"
        }
        return line
    }
}
