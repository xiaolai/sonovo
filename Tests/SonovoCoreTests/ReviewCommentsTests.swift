import Foundation
import Testing
@testable import SonovoCore

@Suite("Review comments")
struct ReviewCommentsTests {
    private func range(of text: String, in source: String) -> Range<Int> {
        let ns = source as NSString
        let found = ns.range(of: text)
        return found.location..<(found.location + found.length)
    }

    @Test("An unchanged selection resolves exactly")
    func exact() throws {
        let source = "One two three.\n"
        let selection = range(of: "two", in: source)
        let anchor = try #require(
            ReviewAnchorResolver.makeAnchor(
                source: source,
                selection: selection
            )
        )
        #expect(anchor.quote == "two")
        #expect(anchor.line == 1)
        #expect(anchor.column == 4)
        #expect(
            ReviewAnchorResolver.resolve(anchor, in: source)
                == .exact(selection)
        )
    }

    @Test("A unique quote follows an edit that moves it")
    func driftUnique() throws {
        let source = "One two three.\n"
        let anchor = try #require(
            ReviewAnchorResolver.makeAnchor(
                source: source,
                selection: range(of: "two", in: source)
            )
        )
        let edited = "Inserted line.\nOne two three.\n"
        let expected = range(of: "two", in: edited)
        #expect(
            ReviewAnchorResolver.resolve(anchor, in: edited)
                == .drifted(expected)
        )
    }

    @Test("Context picks the right one of two identical quotes")
    func contextDisambiguation() throws {
        let source = "alpha note beta\n\ngamma note delta\n"
        let second = (source as NSString).range(
            of: "note",
            options: [],
            range: NSRange(location: 10, length: 18)
        )
        let anchor = try #require(
            ReviewAnchorResolver.makeAnchor(
                source: source,
                selection: second.location..<(second.location + 4)
            )
        )
        let edited = "prefix\n" + source
        let resolution = ReviewAnchorResolver.resolve(anchor, in: edited)
        guard case let .drifted(range) = resolution else {
            Issue.record("expected drift, got \(resolution)")
            return
        }
        #expect(
            (edited as NSString).substring(with: NSRange(
                location: range.lowerBound,
                length: range.count
            )) == "note"
        )
        // The chosen occurrence must be the one after "gamma", not "alpha".
        let before = (edited as NSString).substring(
            to: range.lowerBound
        )
        #expect(before.hasSuffix("gamma "))
    }

    @Test("A quote whose context no longer matches any occurrence is ambiguous")
    func ambiguous() throws {
        let source = "alpha note beta"
        let anchor = try #require(
            ReviewAnchorResolver.makeAnchor(
                source: source,
                selection: range(of: "note", in: source)
            )
        )
        let edited = "one note two\n\nthree note four"
        #expect(
            ReviewAnchorResolver.resolve(anchor, in: edited)
                == .unresolved(.ambiguous)
        )
    }

    @Test("A deleted quote is missing, never guessed")
    func missing() throws {
        let source = "One two three.\n"
        let anchor = try #require(
            ReviewAnchorResolver.makeAnchor(
                source: source,
                selection: range(of: "two", in: source)
            )
        )
        #expect(
            ReviewAnchorResolver.resolve(anchor, in: "One  three.\n")
                == .unresolved(.missing)
        )
        #expect(
            ReviewAnchorResolver.resolve(anchor, in: "One TWO three.\n")
                == .unresolved(.missing)
        )
    }

    @Test("UTF-16 offsets survive emoji and CJK text")
    func utf16Offsets() throws {
        let source = "😀 中文 note 终\n"
        let selection = range(of: "note", in: source)
        let anchor = try #require(
            ReviewAnchorResolver.makeAnchor(
                source: source,
                selection: selection
            )
        )
        #expect(anchor.offset == selection.lowerBound)
        #expect(anchor.length == 4)
        #expect(
            ReviewAnchorResolver.resolve(anchor, in: source)
                == .exact(selection)
        )
    }

    @Test("The sidecar path is hidden and beside the document")
    func sidecarPath() {
        let url = URL(fileURLWithPath: "/tmp/show/doc.md")
        #expect(
            ReviewAnchorResolver.sidecarURL(for: url).path
                == "/tmp/show/.doc.md.review.json"
        )
    }

    @Test("The sidecar JSON round-trips with dates and resolved state")
    func jsonRoundTrip() throws {
        let anchor = try #require(
            ReviewAnchorResolver.makeAnchor(
                source: "One two three.\n",
                selection: 4..<7
            )
        )
        let comment = ReviewComment(
            author: "example-author",
            body: "Check this.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let thread = ReviewThread(
            author: "example-author",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            resolved: true,
            anchor: anchor,
            comments: [comment]
        )
        let document = ReviewDocument(
            documentName: "doc.md",
            documentIdentity: "abc",
            threads: [thread]
        )
        let data = try document.encoded()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"version\" : 1"))
        #expect(text.contains("\"resolved\" : true"))
        let decoded = try ReviewDocument.decoded(data)
        #expect(decoded == document)
    }

    @Test("Corrupt JSON is refused")
    func corruptJSON() {
        #expect(throws: (any Error).self) {
            try ReviewDocument.decoded(Data("{".utf8))
        }
    }

    @Test("Threads mutate, resolve, reply, and delete without touching source")
    func threadMutations() throws {
        let source = "alpha note beta\n\ngamma note delta\n"
        let anchor = try #require(
            ReviewAnchorResolver.makeAnchor(
                source: source,
                selection: range(of: "note", in: source)
            )
        )
        var document = ReviewDocument(
            documentName: "doc.md",
            documentIdentity: "id"
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let added = document.addThread(
            anchor: anchor,
            author: "  example-author ",
            body: "  First.  ",
            at: start
        )
        let thread = try #require(added)
        #expect(thread.author == "example-author")
        #expect(thread.comments.first?.body == "First.")
        #expect(document.openThreadCount == 1)
        let rejected = document.addThread(
            anchor: anchor,
            author: "a",
            body: "   ",
            at: start
        )
        #expect(rejected == nil)

        let reply = document.reply(
            to: thread.id,
            author: "editor",
            body: "Reply.",
            at: start.addingTimeInterval(1)
        )
        #expect(reply != nil)
        #expect(
            document.threads[0].updatedAt
                == start.addingTimeInterval(1)
        )
        let didResolve = document.setResolved(true, threadID: thread.id)
        #expect(didResolve)
        #expect(document.openThreadCount == 0)
        #expect(document.threads[0].resolved)
        let didReopen = document.setResolved(false, threadID: thread.id)
        #expect(didReopen)
        let didRemove = document.removeThread(thread.id)
        #expect(didRemove)
        #expect(document.threads.isEmpty)
        let removedAgain = document.removeThread(thread.id)
        #expect(!removedAgain)
        #expect(source == "alpha note beta\n\ngamma note delta\n")
    }

    @Test("Placements sort by position and keep unanchored threads visible")
    func placements() throws {
        let source = "alpha note beta\n\ngamma note delta\n"
        let second = (source as NSString).range(
            of: "note",
            options: [],
            range: NSRange(location: 10, length: 18)
        )
        let firstAnchor = try #require(
            ReviewAnchorResolver.makeAnchor(
                source: source,
                selection: range(of: "note", in: source)
            )
        )
        let secondAnchor = try #require(
            ReviewAnchorResolver.makeAnchor(
                source: source,
                selection: second.location..<(second.location + 4)
            )
        )
        let missingAnchor = try #require(
            ReviewAnchorResolver.makeAnchor(
                source: "deleted quote here",
                selection: range(of: "quote", in: "deleted quote here")
            )
        )
        var document = ReviewDocument(
            documentName: "doc.md",
            documentIdentity: "id"
        )
        let later = document.addThread(
            anchor: secondAnchor,
            author: "a",
            body: "second",
            at: Date(timeIntervalSince1970: 1_700_000_002)
        )
        let earlier = document.addThread(
            anchor: firstAnchor,
            author: "a",
            body: "first",
            at: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let gone = document.addThread(
            anchor: missingAnchor,
            author: "a",
            body: "gone",
            at: Date(timeIntervalSince1970: 1_700_000_003)
        )
        let placements = document.placements(in: source)
        #expect(placements.map(\.id) == [
            earlier?.id, later?.id, gone?.id,
        ])
        let firstRange = range(of: "note", in: source)
        #expect(placements[0].resolution == .exact(firstRange))
        #expect(placements[2].range == nil)
        #expect(placements[2].resolution == .unresolved(.missing))
    }
}
