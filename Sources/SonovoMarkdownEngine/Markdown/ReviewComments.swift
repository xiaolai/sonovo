import Foundation

/// One comment in a review thread.
public struct ReviewComment: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let author: String
    public let body: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        author: String,
        body: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = ReviewTimestamp.normalized(createdAt)
    }
}

/// Sidecar timestamps are ISO 8601 whole seconds. Normalizing on the way in
/// makes an encode/decode round trip exact, so a reload never produces a
/// document that differs from what was saved.
enum ReviewTimestamp {
    static func normalized(_ date: Date) -> Date {
        Date(
            timeIntervalSince1970: date.timeIntervalSince1970
                .rounded(.down)
        )
    }
}

/// A source anchor stored with enough context to survive edits.
///
/// Offsets are UTF-16, like every other source position in the app. The
/// quoted text and its surrounding context are the authority after an edit;
/// the stored offset is only the fast path.
public struct ReviewAnchor: Codable, Equatable, Sendable {
    /// UTF-16 offset at creation.
    public let offset: Int
    public let length: Int
    /// 1-based line at creation, for display when the quote is gone.
    public let line: Int
    /// 0-based UTF-16 column at creation.
    public let column: Int
    public let quote: String
    public let contextBefore: String
    public let contextAfter: String
    public let contextHash: String

    public init(
        offset: Int,
        length: Int,
        line: Int,
        column: Int,
        quote: String,
        contextBefore: String,
        contextAfter: String
    ) {
        self.offset = max(0, offset)
        self.length = max(0, length)
        self.line = max(1, line)
        self.column = max(0, column)
        self.quote = quote
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.contextHash = Self.hash(
            quote: quote,
            before: contextBefore,
            after: contextAfter
        )
    }

    static func hash(quote: String, before: String, after: String) -> String {
        ReviewDigest.hex(
            Data("\(quote)\u{0}\(before)\u{0}\(after)".utf8)
        )
    }

    /// Decode through the validating initializer. A synthesized decoder
    /// would install negative offsets and arbitrary lengths straight from a
    /// sidecar and let them reach `NSString` substring calls.
    private enum CodingKeys: String, CodingKey {
        case offset
        case length
        case line
        case column
        case quote
        case contextBefore
        case contextAfter
        case contextHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            offset: try container.decode(Int.self, forKey: .offset),
            length: try container.decode(Int.self, forKey: .length),
            line: try container.decode(Int.self, forKey: .line),
            column: try container.decode(Int.self, forKey: .column),
            quote: try container.decode(String.self, forKey: .quote),
            contextBefore: try container.decode(
                String.self,
                forKey: .contextBefore
            ),
            contextAfter: try container.decode(
                String.self,
                forKey: .contextAfter
            )
        )
    }
}

/// One review thread: an anchor, its comments, and its resolved state.
public struct ReviewThread: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var author: String
    public var createdAt: Date
    public var updatedAt: Date
    public var resolved: Bool
    public var anchor: ReviewAnchor
    public var comments: [ReviewComment]

    public init(
        id: UUID = UUID(),
        author: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        resolved: Bool = false,
        anchor: ReviewAnchor,
        comments: [ReviewComment] = []
    ) {
        self.id = id
        self.author = author
        self.createdAt = ReviewTimestamp.normalized(createdAt)
        self.updatedAt = ReviewTimestamp.normalized(updatedAt)
        self.resolved = resolved
        self.anchor = anchor
        self.comments = comments
    }
}

/// The sidecar's whole content. The document itself is never referenced by
/// absolute path: the sidecar sits beside it and carries the filename and a
/// content identity, so moving the pair together stays valid.
public struct ReviewDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// The sidecar format this build writes and accepts.
    public var version: Int
    /// The document's filename at the time the sidecar was written.
    public var documentName: String
    /// An identity derived from the document's content when the sidecar was
    /// last written; empty when it could not be computed.
    public var documentIdentity: String
    public var threads: [ReviewThread]

    public init(
        version: Int = ReviewDocument.currentVersion,
        documentName: String,
        documentIdentity: String,
        threads: [ReviewThread] = []
    ) {
        self.version = version
        self.documentName = documentName
        self.documentIdentity = documentIdentity
        self.threads = threads
    }

    /// Pretty-printed, sorted-key JSON so the sidecar stays diffable and
    /// readable by a person or a CLI.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decoded(_ data: Data) throws -> ReviewDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ReviewDocument.self, from: data)
    }
}

/// The outcome of resolving a stored anchor against current source.
public enum ReviewAnchorResolution: Equatable, Sendable {
    /// The stored range still holds exactly the quoted text.
    case exact(Range<Int>)
    /// The quote moved; the context matched exactly once.
    case drifted(Range<Int>)
    /// The quote cannot be located without guessing.
    case unresolved(ReviewAnchorFailure)
}

public enum ReviewAnchorFailure: String, Equatable, Sendable {
    /// The quoted text no longer appears.
    case missing
    /// The quoted text appears more than once and context cannot pick one.
    case ambiguous
}

/// Builds and resolves review anchors over canonical source.
public enum ReviewAnchorResolver {
    /// The number of UTF-16 code units kept on each side for context.
    public static let contextLength = 40

    public static func makeAnchor(
        source: String,
        selection: Range<Int>
    ) -> ReviewAnchor? {
        let ns = source as NSString
        let lower = max(0, min(selection.lowerBound, ns.length))
        let upper = max(lower, min(selection.upperBound, ns.length))
        guard upper > lower else { return nil }
        let quote = ns.substring(
            with: NSRange(location: lower, length: upper - lower)
        )
        let beforeStart = max(0, lower - contextLength)
        let before = ns.substring(
            with: NSRange(location: beforeStart, length: lower - beforeStart)
        )
        let afterLength = min(contextLength, ns.length - upper)
        let after = ns.substring(
            with: NSRange(location: upper, length: afterLength)
        )
        return ReviewAnchor(
            offset: lower,
            length: upper - lower,
            line: line(at: lower, in: ns),
            column: column(at: lower, in: ns),
            quote: quote,
            contextBefore: before,
            contextAfter: after
        )
    }

    public static func resolve(
        _ anchor: ReviewAnchor,
        in source: String
    ) -> ReviewAnchorResolution {
        let ns = source as NSString
        let (storedEnd, storedOverflow) =
            anchor.offset.addingReportingOverflow(anchor.length)
        if !storedOverflow,
           anchor.length > 0,
           anchor.offset >= 0,
           storedEnd <= ns.length,
           ns.substring(
               with: NSRange(location: anchor.offset, length: anchor.length)
           ) == anchor.quote {
            // Matching text alone is not enough: copy or insert another
            // occurrence at the old offset and the quote would attach to the
            // wrong one. The context must still match too.
            let beforeStart = max(0, anchor.offset - contextLength)
            let before = ns.substring(
                with: NSRange(
                    location: beforeStart,
                    length: anchor.offset - beforeStart
                )
            )
            let afterLength = min(contextLength, ns.length - storedEnd)
            let after = ns.substring(
                with: NSRange(location: storedEnd, length: afterLength)
            )
            if ReviewAnchor.hash(
                quote: anchor.quote,
                before: before,
                after: after
            ) == anchor.contextHash {
                return .exact(anchor.offset..<storedEnd)
            }
        }

        guard !anchor.quote.isEmpty else {
            return .unresolved(.missing)
        }
        // Literal, overlapping matches: canonical-equivalence matching can
        // return a range whose length differs from the stored quote, and
        // skipping by the whole match misses a nested occurrence.
        var occurrences: [NSRange] = []
        var search = 0
        while search <= ns.length {
            let found = ns.range(
                of: anchor.quote,
                options: [.literal],
                range: NSRange(
                    location: search,
                    length: ns.length - search
                )
            )
            if found.location == NSNotFound { break }
            occurrences.append(found)
            // One unit, not the match length: `aa` in `aaa` occurs at 0 and
            // at 1, and both are candidates for the moved quote.
            search = found.location + 1
        }
        guard !occurrences.isEmpty else {
            return .unresolved(.missing)
        }
        if occurrences.count == 1, let only = occurrences.first {
            return .drifted(
                only.location..<(only.location + only.length)
            )
        }

        let scored = occurrences.map { occurrence -> (NSRange, Int) in
            let location = occurrence.location
            let length = occurrence.length
            let beforeStart = max(0, location - contextLength)
            let before = ns.substring(
                with: NSRange(
                    location: beforeStart,
                    length: location - beforeStart
                )
            )
            let afterStart = location + length
            let afterLength = min(contextLength, ns.length - afterStart)
            let after = ns.substring(
                with: NSRange(
                    location: afterStart,
                    length: afterLength
                )
            )
            let hash = ReviewAnchor.hash(
                quote: anchor.quote,
                before: before,
                after: after
            )
            if hash == anchor.contextHash {
                return (occurrence, Int.max)
            }
            let beforeScore = commonSuffixLength(
                before,
                anchor.contextBefore
            )
            let afterScore = commonPrefixLength(
                after,
                anchor.contextAfter
            )
            return (occurrence, beforeScore + afterScore)
        }
        let best = scored.map(\.1).max() ?? 0
        let winners = scored.filter { $0.1 == best }
        guard best > 0, winners.count == 1, let winner = winners.first else {
            return .unresolved(.ambiguous)
        }
        return .drifted(
            winner.0.location..<(winner.0.location + winner.0.length)
        )
    }

    /// A content identity for the document a sidecar belongs to. It is
    /// informational: anchors resolve from quotes, so an edited document does
    /// not invalidate its threads.
    public static func documentIdentity(of source: String) -> String {
        ReviewDigest.hex(Data(source.utf8))
    }

    /// The 1-based line containing `offset`, for display.
    public static func lineNumber(at offset: Int, in source: String) -> Int {
        line(at: offset, in: source as NSString)
    }

    /// `.name.review.json` beside the document.
    public static func sidecarURL(for documentURL: URL) -> URL {
        documentURL.deletingLastPathComponent().appendingPathComponent(
            ".\(documentURL.lastPathComponent).review.json"
        )
    }

    // MARK: - Position helpers

    private static func line(at offset: Int, in ns: NSString) -> Int {
        // A decoded anchor may carry a negative offset; `0..<(-1)` traps.
        let clamped = min(max(offset, 0), ns.length)
        var line = 1
        for index in 0..<clamped
        where ns.character(at: index) == 0x0A {
            line += 1
        }
        return line
    }

    private static func column(at offset: Int, in ns: NSString) -> Int {
        var start = min(max(offset, 0), ns.length)
        let clamped = start
        while start > 0, ns.character(at: start - 1) != 0x0A {
            start -= 1
        }
        return clamped - start
    }

    private static func commonPrefixLength(
        _ lhs: String,
        _ rhs: String
    ) -> Int {
        var count = 0
        let left = Array(lhs.utf16)
        let right = Array(rhs.utf16)
        while count < left.count, count < right.count,
              left[count] == right[count] {
            count += 1
        }
        return count
    }

    private static func commonSuffixLength(
        _ lhs: String,
        _ rhs: String
    ) -> Int {
        var count = 0
        let left = Array(lhs.utf16)
        let right = Array(rhs.utf16)
        while count < left.count, count < right.count,
              left[left.count - 1 - count] == right[right.count - 1 - count] {
            count += 1
        }
        return count
    }
}

// MARK: - Mutations

extension ReviewDocument {
    /// Adds a thread anchored at `anchor`. An empty body adds nothing.
    @discardableResult
    public mutating func addThread(
        anchor: ReviewAnchor,
        author: String,
        body: String,
        at date: Date = Date()
    ) -> ReviewThread? {
        guard let comment = Self.comment(
            author: author,
            body: body,
            createdAt: date
        ) else {
            return nil
        }
        let thread = ReviewThread(
            author: comment.author,
            createdAt: date,
            updatedAt: date,
            anchor: anchor,
            comments: [comment]
        )
        threads.append(thread)
        return thread
    }

    @discardableResult
    public mutating func reply(
        to threadID: UUID,
        author: String,
        body: String,
        at date: Date = Date()
    ) -> ReviewComment? {
        guard let index = threads.firstIndex(where: { $0.id == threadID }),
              let comment = Self.comment(
                  author: author,
                  body: body,
                  createdAt: date
              ) else {
            return nil
        }
        threads[index].comments.append(comment)
        threads[index].updatedAt = ReviewTimestamp.normalized(date)
        return comment
    }

    @discardableResult
    public mutating func setResolved(
        _ resolved: Bool,
        threadID: UUID,
        at date: Date = Date()
    ) -> Bool {
        guard let index = threads.firstIndex(where: { $0.id == threadID })
        else {
            return false
        }
        threads[index].resolved = resolved
        threads[index].updatedAt = ReviewTimestamp.normalized(date)
        return true
    }

    @discardableResult
    public mutating func removeThread(_ threadID: UUID) -> Bool {
        guard let index = threads.firstIndex(where: { $0.id == threadID })
        else {
            return false
        }
        threads.remove(at: index)
        return true
    }

    public var openThreadCount: Int {
        threads.count(where: { !$0.resolved })
    }
}

extension ReviewComment {
    static func normalized(_ author: String) -> String {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Anonymous" : trimmed
    }
}

extension ReviewDocument {
    /// A validated comment: a body of only whitespace is not a comment.
    private static func comment(
        author: String,
        body: String,
        createdAt: Date
    ) -> ReviewComment? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ReviewComment(
            author: ReviewComment.normalized(author),
            body: trimmed,
            createdAt: createdAt
        )
    }
}

// MARK: - Display

/// One thread resolved against current source, ready for a list or a margin.
public struct ReviewThreadPlacement: Equatable, Sendable, Identifiable {
    public let thread: ReviewThread
    public let resolution: ReviewAnchorResolution

    public init(thread: ReviewThread, resolution: ReviewAnchorResolution) {
        self.thread = thread
        self.resolution = resolution
    }

    public var id: UUID { thread.id }

    public var range: Range<Int>? {
        switch resolution {
        case let .exact(range), let .drifted(range):
            return range
        case .unresolved:
            return nil
        }
    }

    public var isAnchored: Bool { range != nil }
    public var isOpen: Bool { !thread.resolved }
}

extension ReviewDocument {
    /// Resolves every thread against `source`: anchored threads ordered by
    /// position, unanchored threads after them so a missing quote stays
    /// visible instead of disappearing.
    public func placements(in source: String) -> [ReviewThreadPlacement] {
        threads.map { thread in
            ReviewThreadPlacement(
                thread: thread,
                resolution: ReviewAnchorResolver.resolve(
                    thread.anchor,
                    in: source
                )
            )
        }.sorted { lhs, rhs in
            switch (lhs.range, rhs.range) {
            case let (left?, right?):
                if left.lowerBound != right.lowerBound {
                    return left.lowerBound < right.lowerBound
                }
                return tieBreak(lhs, rhs)
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return tieBreak(lhs, rhs)
            }
        }
    }

    private func tieBreak(
        _ lhs: ReviewThreadPlacement,
        _ rhs: ReviewThreadPlacement
    ) -> Bool {
        if lhs.thread.createdAt != rhs.thread.createdAt {
            return lhs.thread.createdAt < rhs.thread.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
