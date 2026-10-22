import Foundation
import SonovoCore

/// A line terminator, kept because a final-newline change is a real change.
enum CodeLineTerminator: String, Sendable, Equatable {
    case lf = "\n"
    case crlf = "\r\n"
    case none = ""
}

/// One line with its exact bytes. Equality is byte equality of the content
/// **and** the terminator; Swift `String` equality is canonical-equivalence
/// aware and would hide a real byte difference.
struct CodeDiffLine: Sendable {
    let content: Data
    let terminator: CodeLineTerminator
    let text: String
    let number: Int
}

extension CodeDiffLine: Equatable {
    static func == (lhs: CodeDiffLine, rhs: CodeDiffLine) -> Bool {
        lhs.content == rhs.content && lhs.terminator == rhs.terminator
    }
}

struct CodeDiffRow: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case equal
        case delete
        case insert
    }

    let id: Int
    let kind: Kind
    let left: CodeDiffLine?
    let right: CodeDiffLine?
}

struct CodeDiffHunk: Identifiable, Sendable, Equatable {
    let id: Int
    let header: String
    let rows: [CodeDiffRow]
    let leftStart: Int
    let rightStart: Int
    let addedCount: Int
    let removedCount: Int
}

/// A complete, display-ready diff.
struct CodeDiffModel: Sendable, Equatable {
    let leftLabel: String
    let rightLabel: String
    let rows: [CodeDiffRow]
    let hunks: [CodeDiffHunk]
    let addedCount: Int
    let removedCount: Int
    let leftLineCount: Int
    let rightLineCount: Int

    var hasChanges: Bool { addedCount > 0 || removedCount > 0 }

    /// A unified diff as text, for "Copy Diff". Each record carries the
    /// line's own terminator so CRLF and a missing final newline survive the
    /// copy.
    var unifiedText: String {
        var output = "--- \(leftLabel)\n+++ \(rightLabel)\n"
        for hunk in hunks {
            output += hunk.header + "\n"
            for row in hunk.rows {
                switch row.kind {
                case .equal:
                    output += " " + (row.left?.text ?? "")
                    output += terminatorOutput(row.left?.terminator)
                case .delete:
                    output += "-" + (row.left?.text ?? "")
                    output += terminatorOutput(row.left?.terminator)
                case .insert:
                    output += "+" + (row.right?.text ?? "")
                    output += terminatorOutput(row.right?.terminator)
                }
            }
        }
        return output
    }

    private func terminatorOutput(
        _ terminator: CodeLineTerminator?
    ) -> String {
        switch terminator {
        case .some(.lf):
            return "\n"
        case .some(.crlf):
            return "\r\n"
        case .some(.none):
            return "\n\\ No newline at end of file\n"
        case .none:
            return ""
        }
    }

    /// Checks the per-side caps before computing anything. The caller keeps
    /// both files openable on their own; only the diff is unavailable.
    static func availability(
        left: DiskSnapshot,
        right: DiskSnapshot,
        leftLabel: String,
        rightLabel: String
    ) -> CodeDiffAvailability {
        if left.byteCount > CodeLimits.diffBytesPerSide {
            return .unavailable(
                "Diff unavailable: \(leftLabel) is above 2 MB."
            )
        }
        if right.byteCount > CodeLimits.diffBytesPerSide {
            return .unavailable(
                "Diff unavailable: \(rightLabel) is above 2 MB."
            )
        }
        let leftLines = lines(in: left.bytes)
        let rightLines = lines(in: right.bytes)
        if leftLines.count > CodeLimits.diffLinesPerSide {
            return .unavailable(
                "Diff unavailable: \(leftLabel) has more than 50,000 lines."
            )
        }
        if rightLines.count > CodeLimits.diffLinesPerSide {
            return .unavailable(
                "Diff unavailable: \(rightLabel) has more than 50,000 lines."
            )
        }
        return .available(
            CodeDiffPair(
                leftLabel: leftLabel,
                rightLabel: rightLabel,
                left: left,
                right: right
            )
        )
    }

    /// Builds the model. Preconditions are the caps checked by
    /// `availability`; this function still refuses to run an unbounded
    /// comparison on a pathological middle.
    static func compare(_ pair: CodeDiffPair) -> CodeDiffModel {
        let leftLines = lines(in: pair.left.bytes)
        let rightLines = lines(in: pair.right.bytes)
        let steps = editSteps(leftLines, rightLines)
        var rows: [CodeDiffRow] = []
        rows.reserveCapacity(steps.count)
        var added = 0
        var removed = 0
        for (index, step) in steps.enumerated() {
            if Task.isCancelled { break }
            switch step {
            case .equal(let left, let right):
                rows.append(
                    CodeDiffRow(
                        id: index,
                        kind: .equal,
                        left: left,
                        right: right
                    )
                )
            case .delete(let left):
                removed += 1
                rows.append(
                    CodeDiffRow(
                        id: index,
                        kind: .delete,
                        left: left,
                        right: nil
                    )
                )
            case .insert(let right):
                added += 1
                rows.append(
                    CodeDiffRow(
                        id: index,
                        kind: .insert,
                        left: nil,
                        right: right
                    )
                )
            }
        }
        return CodeDiffModel(
            leftLabel: pair.leftLabel,
            rightLabel: pair.rightLabel,
            rows: rows,
            hunks: makeHunks(rows),
            addedCount: added,
            removedCount: removed,
            leftLineCount: leftLines.count,
            rightLineCount: rightLines.count
        )
    }

    // MARK: - Lines

    /// Splits exact bytes into line records. A trailing newline does not
    /// create a phantom empty line; a missing final newline is recorded on
    /// the last line.
    static func lines(in bytes: Data) -> [CodeDiffLine] {
        guard !bytes.isEmpty else { return [] }
        var lines: [CodeDiffLine] = []
        var lineStart = bytes.startIndex
        var index = bytes.startIndex
        var number = 1
        while index < bytes.endIndex {
            if bytes[index] == 0x0A {
                var contentEnd = index
                var terminator = CodeLineTerminator.lf
                if contentEnd > lineStart, bytes[contentEnd - 1] == 0x0D {
                    contentEnd -= 1
                    terminator = .crlf
                }
                lines.append(
                    makeLine(
                        bytes[lineStart..<contentEnd],
                        terminator: terminator,
                        number: number
                    )
                )
                number += 1
                lineStart = bytes.index(after: index)
            }
            index = bytes.index(after: index)
        }
        if lineStart < bytes.endIndex {
            // A trailing lone CR is content, not a terminator; dropping it
            // would make `a\r` and `a` compare equal.
            let content = bytes[lineStart..<bytes.endIndex]
            lines.append(
                makeLine(content, terminator: .none, number: number)
            )
        }
        return lines
    }

    private static func makeLine(
        _ content: Data.SubSequence,
        terminator: CodeLineTerminator,
        number: Int
    ) -> CodeDiffLine {
        let data = Data(content)
        return CodeDiffLine(
            content: data,
            terminator: terminator,
            text: String(decoding: data, as: UTF8.self),
            number: number
        )
    }

    // MARK: - Edit script

    private enum Step {
        case equal(CodeDiffLine, CodeDiffLine)
        case delete(CodeDiffLine)
        case insert(CodeDiffLine)
    }

    private static func editSteps(
        _ left: [CodeDiffLine],
        _ right: [CodeDiffLine]
    ) -> [Step] {
        var steps: [Step] = []

        // Trim the common prefix and suffix first: a local edit in a large
        // file then costs the edit, not the file.
        var prefix = 0
        while prefix < left.count, prefix < right.count,
              left[prefix] == right[prefix] {
            steps.append(.equal(left[prefix], right[prefix]))
            prefix += 1
        }
        var leftEnd = left.count
        var rightEnd = right.count
        var suffix: [Step] = []
        while leftEnd > prefix, rightEnd > prefix,
              left[leftEnd - 1] == right[rightEnd - 1] {
            leftEnd -= 1
            rightEnd -= 1
            suffix.append(.equal(left[leftEnd], right[rightEnd]))
        }

        let leftMiddle = Array(left[prefix..<leftEnd])
        let rightMiddle = Array(right[prefix..<rightEnd])
        steps.append(
            contentsOf: middleSteps(leftMiddle, rightMiddle)
        )
        steps.append(contentsOf: suffix.reversed())
        return steps
    }

    /// The standard library's Myers implementation is exact and linear
    /// space. A pathological middle (both sides huge and completely
    /// different) would be quadratic in wall time, so it falls back to an
    /// honest coarse replace rather than hanging the viewer.
    private static func middleSteps(
        _ left: [CodeDiffLine],
        _ right: [CodeDiffLine]
    ) -> [Step] {
        if left.isEmpty {
            return right.map { .insert($0) }
        }
        if right.isEmpty {
            return left.map { .delete($0) }
        }
        if max(left.count, right.count) > 20_000 {
            // A rewritten region this large is reported as a coarse
            // replacement; the comparison must not grow unbounded.
            return left.map { .delete($0) } + right.map { .insert($0) }
        }

        if Task.isCancelled {
            return []
        }
        // `right.difference(from: left)` removes lines from the left and
        // inserts lines into the right; the offsets below are left and right
        // indices respectively.
        let difference = right.difference(from: left)
        var removals: [Int: CodeDiffLine] = [:]
        var insertions: [Int: CodeDiffLine] = [:]
        for change in difference {
            switch change {
            case .remove(let offset, _, _):
                removals[offset] = left[offset]
            case .insert(let offset, _, _):
                insertions[offset] = right[offset]
            }
        }

        var steps: [Step] = []
        var leftIndex = 0
        var rightIndex = 0
        while leftIndex < left.count || rightIndex < right.count {
            if let removal = removals[leftIndex] {
                steps.append(.delete(removal))
                leftIndex += 1
            } else if let insertion = insertions[rightIndex] {
                steps.append(.insert(insertion))
                rightIndex += 1
            } else if leftIndex < left.count, rightIndex < right.count {
                steps.append(.equal(left[leftIndex], right[rightIndex]))
                leftIndex += 1
                rightIndex += 1
            } else {
                break
            }
        }
        return steps
    }

    // MARK: - Hunks

    private static let contextLines = 3

    private static func makeHunks(_ rows: [CodeDiffRow]) -> [CodeDiffHunk] {
        let changed = rows.indices.filter { rows[$0].kind != .equal }
        guard !changed.isEmpty else { return [] }

        var ranges: [ClosedRange<Int>] = []
        for index in changed {
            let lower = max(0, index - contextLines)
            let upper = min(rows.count - 1, index + contextLines)
            if let last = ranges.last, lower <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(
                    last.upperBound,
                    upper
                )
            } else {
                ranges.append(lower...upper)
            }
        }

        return ranges.enumerated().map { hunkIndex, range in
            let slice = Array(rows[range])
            let leftNumbers = slice.compactMap { $0.left?.number }
            let rightNumbers = slice.compactMap { $0.right?.number }
            let leftStart = leftNumbers.first ?? 0
            let rightStart = rightNumbers.first ?? 0
            let added = slice.filter { $0.kind == .insert }.count
            let removed = slice.filter { $0.kind == .delete }.count
            let header = "@@ -\(leftStart),\(leftNumbers.count) "
                + "+\(rightStart),\(rightNumbers.count) @@"
            return CodeDiffHunk(
                id: hunkIndex,
                header: header,
                rows: slice,
                leftStart: leftStart,
                rightStart: rightStart,
                addedCount: added,
                removedCount: removed
            )
        }
    }
}
