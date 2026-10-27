import Foundation

/// Computes one multi-caret edit against one immutable preimage.
///
/// The engine never touches a text view: it validates every range, builds the
/// replacement list descending, produces the new source, and maps every
/// caret through the edit. Applying the replacements and recording the
/// document revision belong to the editor.
public enum MultiCursorEdit {
    public enum Operation: Sendable, Equatable {
        case insert(String)
        case deleteBackward
        case deleteForward
        case replace(String)
        case paste(String)

        public var actionName: String {
            switch self {
            case .insert: "Typing"
            case .deleteBackward: "Delete Backward"
            case .deleteForward: "Delete Forward"
            case .replace: "Replace"
            case .paste: "Paste"
            }
        }
    }

    public struct Replacement: Sendable, Equatable {
        public let range: Range<Int>
        public let text: String

        public init(range: Range<Int>, text: String) {
            self.range = range
            self.text = text
        }
    }

    public struct Output: Sendable, Equatable {
        /// The preimage the batch was computed against.
        public let previousSource: String
        public let source: String
        /// Whether the replacements actually alter the text. Computed without
        /// a whole-string comparison whenever a length delta settles it: a
        /// `String ==` walks graphemes at ~10 MB/s, which a 1 MB document
        /// cannot afford per keystroke.
        public let changed: Bool
        /// Descending, so applying them in order needs no offset math.
        public let replacements: [Replacement]
        /// Post-edit carets, all collapsed to the end of their edit.
        public let selection: MultiCursorSelection
        public let actionName: String
    }

    public enum Failure: Error, Equatable, Sendable {
        case outOfBounds(Int)
        case graphemeSplit(Int)
        case overlapping
        case invalidSelection(MultiCursorSelection.Failure)
        /// The projected result would exceed the document's replacement
        /// limit. Reported before the result is built so a large paste at
        /// many carets cannot allocate gigabytes first.
        case resultTooLarge(Int)
    }

    public static func apply(
        _ operation: Operation,
        to source: String,
        selection: MultiCursorSelection
    ) -> Result<Output, Failure> {
        let ns = source as NSString
        var edits: [(range: Range<Int>, text: String)] = []
        var order: [Int] = []
        for caret in selection.carets {
            // Validate the caret as the selection named it, before any
            // operation-specific expansion. A deletion turns a bare caret
            // into the cluster beside it; when the caret itself sits inside
            // a cluster of this source, that expansion would hide the stale
            // endpoint and delete text instead of refusing.
            if let failure = failureForOffset(caret.anchor, in: source)
                ?? failureForOffset(caret.active, in: source) {
                return .failure(failure)
            }
            let edit: (range: Range<Int>, text: String)?
            switch operation {
            case .insert(let text), .replace(let text), .paste(let text):
                edit = (caret.range, text)
            case .deleteBackward:
                edit = deletionRange(
                    for: caret,
                    backward: true,
                    in: ns
                ).map { ($0, "") }
            case .deleteForward:
                edit = deletionRange(
                    for: caret,
                    backward: false,
                    in: ns
                ).map { ($0, "") }
            }
            guard let edit else {
                order.append(-1)
                continue
            }
            guard edit.range.lowerBound >= 0,
                  edit.range.upperBound <= ns.length else {
                return .failure(.outOfBounds(edit.range.lowerBound))
            }
            // The expanded deletion range must also be a pair of boundaries
            // in this source; an offset that was a boundary in the source
            // the selection came from can fall inside a cluster here.
            if let failure = failureForOffset(edit.range.lowerBound, in: source)
                ?? failureForOffset(edit.range.upperBound, in: source) {
                return .failure(failure)
            }
            order.append(edits.count)
            edits.append(edit)
        }

        let sorted = edits.sorted {
            $0.range.lowerBound < $1.range.lowerBound
        }
        for pair in zip(sorted, sorted.dropFirst())
        where pair.1.range.lowerBound < pair.0.range.upperBound {
            return .failure(.overlapping)
        }

        var lengthDelta = 0
        // Bound the allocation before building it: a paste at N carets
        // inserts the payload N times, so a 16 MB clipboard at 100 carets
        // would materialise ~1.6 GB before the editor's size check ran.
        //
        // Replacements are applied descending, so the string passes through
        // the suffix sums of their length deltas. The largest of those — not
        // the final size — is what can be allocated, and a batch that shrinks
        // overall but grows in between must still be refused.
        //
        // The limit is in bytes, and one UTF-16 unit encodes as at most three
        // of them, so a unit-space peak of limit/3 or less is safe without
        // measuring the source. Anything larger switches to an exact byte
        // projection, O(source) once, before anything is allocated.
        let limit = DocumentHistoryLimits.maxReplacementBytes
        let addedUnits: Int
        let addedBytes: Int
        switch operation {
        case .insert(let text), .replace(let text), .paste(let text):
            addedUnits = text.utf16.count
            addedBytes = text.utf8.count
        case .deleteBackward, .deleteForward:
            addedUnits = 0
            addedBytes = 0
        }
        var unitSuffix = 0
        var unitPeak = ns.length
        for edit in sorted.reversed() {
            let (next, overflowed) = unitSuffix.addingReportingOverflow(
                addedUnits - edit.range.count
            )
            guard !overflowed else {
                return .failure(.resultTooLarge(.max))
            }
            unitSuffix = next
            let (size, sizeOverflowed) = ns.length.addingReportingOverflow(next)
            guard !sizeOverflowed else {
                return .failure(.resultTooLarge(.max))
            }
            unitPeak = max(unitPeak, size)
        }
        if unitPeak > limit / 3 {
            let sourceBytes = source.utf8.count
            var byteSuffix = 0
            var bytePeak = sourceBytes
            for edit in sorted.reversed() {
                let removed = ns.substring(
                    with: NSRange(
                        location: edit.range.lowerBound,
                        length: edit.range.count
                    )
                ).utf8.count
                let (next, overflowed) = byteSuffix.addingReportingOverflow(
                    addedBytes - removed
                )
                guard !overflowed else {
                    return .failure(.resultTooLarge(.max))
                }
                byteSuffix = next
                let (size, sizeOverflowed) = sourceBytes
                    .addingReportingOverflow(next)
                guard !sizeOverflowed else {
                    return .failure(.resultTooLarge(.max))
                }
                bytePeak = max(bytePeak, size)
            }
            if bytePeak > limit {
                return .failure(.resultTooLarge(max(bytePeak, 0)))
            }
        }

        var changedSource = source
        if !edits.isEmpty {
            // Assemble once from the untouched spans and the payloads. One
            // mutable replacement per caret shifted every later character at
            // each step, so carets near the top of a large source moved
            // hundreds of megabytes before the batch finished.
            var pieces: [String] = []
            pieces.reserveCapacity(edits.count * 2 + 1)
            var cursor = 0
            for edit in sorted {
                if edit.range.lowerBound > cursor {
                    pieces.append(
                        ns.substring(
                            with: NSRange(
                                location: cursor,
                                length: edit.range.lowerBound - cursor
                            )
                        )
                    )
                }
                pieces.append(edit.text)
                cursor = edit.range.upperBound
                // Every edit's text is the operation payload, whose lengths
                // were computed once.
                lengthDelta += addedUnits - edit.range.count
            }
            if cursor < ns.length {
                pieces.append(
                    ns.substring(
                        with: NSRange(
                            location: cursor,
                            length: ns.length - cursor
                        )
                    )
                )
            }
            changedSource = pieces.joined()
        }
        // A non-zero length delta proves the text changed. The comparison is
        // reserved for an equal-length replacement, which may be a no-op.
        // It must be exact code-unit equality: Swift's `String ==` uses
        // canonical equivalence, so a replacement that only changes code
        // units (a precomposed "é" for a decomposed one) would compare equal
        // and be discarded, leaving the document and the view divergent.
        let changed = !edits.isEmpty
            && (lengthDelta != 0
                || !(changedSource as NSString).isEqual(to: source))

        // Each caret lands at the end of its own replacement; edits below it
        // shift that position by their length delta.
        var deltas: [(range: Range<Int>, delta: Int)] = []
        for edit in sorted {
            deltas.append(
                (
                    edit.range,
                    addedUnits - edit.range.count
                )
            )
        }
        var newCarets: [MultiCursorSelection.Caret] = []
        let changedNS = changedSource as NSString
        for (index, caret) in selection.carets.enumerated() {
            // A backward deletion starts left of the caret, so the shift
            // baseline is the edit's lower bound, not the caret's.
            let baseline = order[index] >= 0
                ? edits[order[index]].range.lowerBound
                : caret.range.lowerBound
            let shiftBelow = deltas
                .filter {
                    $0.range.upperBound <= baseline
                        && $0.range.lowerBound < baseline
                }
                .reduce(0) { $0 + $1.delta }
            guard order[index] >= 0 else {
                // A shifted caret can also land inside a cluster a nearby
                // edit merged; snap it for the same reason as the edit case.
                let position = edgeOfCluster(
                    at: caret.active + shiftBelow,
                    in: changedNS
                )
                newCarets.append(
                    MultiCursorSelection.Caret(
                        anchor: position,
                        active: position
                    )
                )
                continue
            }
            let edit = edits[order[index]]
            let position = edgeOfCluster(
                at: baseline
                    + shiftBelow
                    + addedUnits,
                in: changedNS
            )
            newCarets.append(
                MultiCursorSelection.Caret(anchor: position, active: position)
            )
        }
        let newSelection: MultiCursorSelection
        do {
            newSelection = try MultiCursorSelection(
                newCarets,
                primary: selection.primaryIndex,
                source: changedSource
            )
        } catch let failure as MultiCursorSelection.Failure {
            return .failure(.invalidSelection(failure))
        } catch {
            return .failure(.invalidSelection(.invalidPrimary(0)))
        }

        return .success(
            Output(
                previousSource: source,
                source: changedSource,
                changed: changed,
                replacements: sorted.reversed().map {
                    Replacement(range: $0.range, text: $0.text)
                },
                selection: newSelection,
                actionName: operation.actionName
            )
        )
    }

    /// The engine's spelling of a selection validation failure, or nil when
    /// `offset` is a composed-character boundary of `source`.
    private static func failureForOffset(
        _ offset: Int,
        in source: String
    ) -> Failure? {
        do {
            try MultiCursorSelection.validate(offset, in: source)
            return nil
        } catch let failure as MultiCursorSelection.Failure {
            switch failure {
            case .graphemeSplit(let offset):
                return .graphemeSplit(offset)
            case .outOfBounds(let offset):
                return .outOfBounds(offset)
            default:
                return .invalidSelection(failure)
            }
        } catch {
            return .invalidSelection(.invalidPrimary(0))
        }
    }

    /// One grapheme before or after a zero-length caret; the selection itself
    /// when the caret covers text. `nil` means no edit at this caret (start
    /// of the source for backward deletion, end for forward).
    private static func deletionRange(
        for caret: MultiCursorSelection.Caret,
        backward: Bool,
        in ns: NSString
    ) -> Range<Int>? {
        if !caret.range.isEmpty {
            return caret.range
        }
        let offset = caret.active
        if backward {
            guard offset > 0, offset <= ns.length else { return nil }
            let cluster = ns.rangeOfComposedCharacterSequence(at: offset - 1)
            return cluster.location..<(cluster.location + cluster.length)
        }
        guard offset >= 0, offset < ns.length else { return nil }
        let cluster = ns.rangeOfComposedCharacterSequence(at: offset)
        return cluster.location..<(cluster.location + cluster.length)
    }

    /// The nearest offset at or after `offset` that is a grapheme boundary.
    ///
    /// Inserting at a cluster boundary can still leave the post-edit caret
    /// inside a cluster: inserting the base of a combining sequence before an
    /// existing accent merges the two, and the caret then sits between them.
    /// Snapping forward to the cluster end keeps the caret representable
    /// instead of failing the whole batch.
    private static func edgeOfCluster(
        at offset: Int,
        in ns: NSString
    ) -> Int {
        guard offset > 0, offset < ns.length else {
            return min(max(offset, 0), ns.length)
        }
        let cluster = ns.rangeOfComposedCharacterSequence(at: offset)
        guard cluster.location < offset else { return offset }
        return cluster.location + cluster.length
    }
}
