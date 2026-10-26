import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown proposals")
struct MarkdownProposalTests {
    private func hash(_ source: String) -> String {
        ReviewAnchorResolver.documentIdentity(of: source)
    }

    private func proposal(
        for source: String,
        document: String = "doc.md",
        hunks: String
    ) -> String {
        """
        # sonovo-proposal 1
        # document: \(document)
        # base-sha256: \(hash(source))
        --- a/\(document)
        +++ b/\(document)
        \(hunks)
        """
    }

    @Test("A single hunk applies to its exact base")
    func singleHunk() throws {
        let source = "alpha\nnote\nbeta\n"
        let text = proposal(
            for: source,
            hunks: """
            @@ -1,3 +1,3 @@
             alpha
            -note
            +NOTE
             beta
            """
        )
        let parsed = try MarkdownProposal.parse(text)
        #expect(parsed.documentName == "doc.md")
        #expect(parsed.hunks.count == 1)
        #expect(parsed.hunks[0].oldLines == ["alpha", "note", "beta"])
        #expect(parsed.hunks[0].newLines == ["alpha", "NOTE", "beta"])
        let result = try parsed.apply(
            accepting: [1],
            to: source
        )
        #expect(result == "alpha\nNOTE\nbeta\n")
    }

    @Test("Unaccepted hunks leave their regions byte-for-byte unchanged")
    func perHunkAcceptance() throws {
        let source = "one\ntwo\nthree\nfour\nfive\nsix\n"
        let text = proposal(
            for: source,
            hunks: """
            @@ -1,2 +1,2 @@
             one
            -two
            +TWO
            @@ -5,2 +5,2 @@
             five
            -six
            +SIX
            """
        )
        let parsed = try MarkdownProposal.parse(text)
        let firstOnly = try parsed.apply(accepting: [1], to: source)
        #expect(firstOnly == "one\nTWO\nthree\nfour\nfive\nsix\n")
        let secondOnly = try parsed.apply(accepting: [2], to: source)
        #expect(secondOnly == "one\ntwo\nthree\nfour\nfive\nSIX\n")
        let both = try parsed.apply(accepting: [1, 2], to: source)
        #expect(both == "one\nTWO\nthree\nfour\nfive\nSIX\n")
    }

    @Test("No accepted hunks is refused")
    func noSelection() throws {
        let source = "alpha\n"
        let parsed = try MarkdownProposal.parse(
            proposal(
                for: source,
                hunks: """
                @@ -1 +1 @@
                -alpha
                +ALPHA
                """
            )
        )
        #expect(throws: MarkdownProposalError.noHunksSelected) {
            try parsed.apply(accepting: [], to: source)
        }
    }

    @Test("A changed document refuses as stale")
    func staleBase() throws {
        let source = "alpha\nnote\n"
        let parsed = try MarkdownProposal.parse(
            proposal(
                for: source,
                hunks: """
                @@ -1,2 +1,2 @@
                 alpha
                -note
                +NOTE
                """
            )
        )
        #expect(throws: MarkdownProposalError.staleBase) {
            try parsed.apply(accepting: [1], to: source + "extra\n")
        }
    }

    @Test("A matching hash with mismatched context still refuses")
    func hunkOutOfDate() throws {
        let source = "alpha\nnote\n"
        // A hand-edited proposal can carry the right hash and the wrong
        // context; the applier validates the context rather than trusting the
        // header.
        let parsed = MarkdownProposal(
            documentName: "doc.md",
            baseHash: hash(source),
            hunks: [
                ProposalHunk(
                    id: 1,
                    oldStart: 1,
                    oldCount: 2,
                    newStart: 1,
                    newCount: 2,
                    section: "",
                    oldLines: ["alpha", "changed"],
                    newLines: ["alpha", "CHANGED"],
                    oldLastHasNewline: true,
                    newLastHasNewline: true
                ),
            ]
        )
        #expect(throws: MarkdownProposalError.hunkOutOfDate(1)) {
            try parsed.apply(accepting: [1], to: source)
        }
    }

    @Test("Overlapping hunks are refused at parse")
    func overlappingHunks() {
        let source = "a\nb\nc\nd\n"
        let text = proposal(
            for: source,
            hunks: """
            @@ -1,3 +1,3 @@
             a
            -b
            +B
             c
            @@ -2,3 +2,3 @@
             b
            -c
            +C
             d
            """
        )
        #expect(throws: MarkdownProposalError.overlappingHunks) {
            try MarkdownProposal.parse(text)
        }
    }

    @Test("Hunk line counts must match the header")
    func countMismatch() {
        let source = "a\nb\n"
        let text = proposal(
            for: source,
            hunks: """
            @@ -1,3 +1,3 @@
             a
            -b
            +B
            """
        )
        #expect(throws: (any Error).self) {
            try MarkdownProposal.parse(text)
        }
    }

    @Test("Insertions at the start and end keep surrounding bytes")
    func insertions() throws {
        let source = "middle\n"
        let startText = proposal(
            for: source,
            hunks: """
            @@ -0,0 +1 @@
            +first
            """
        )
        let start = try MarkdownProposal.parse(startText)
        #expect(
            try start.apply(accepting: [1], to: source)
                == "first\nmiddle\n"
        )

        let endText = proposal(
            for: source,
            hunks: """
            @@ -1,0 +2 @@
            +last
            """
        )
        let end = try MarkdownProposal.parse(endText)
        #expect(
            try end.apply(accepting: [1], to: source)
                == "middle\nlast\n"
        )
    }

    @Test("An empty document accepts an insertion")
    func insertIntoEmptyDocument() throws {
        let source = ""
        let text = proposal(
            for: source,
            hunks: """
            @@ -0,0 +1,2 @@
            +first
            +second
            """
        )
        let parsed = try MarkdownProposal.parse(text)
        #expect(
            try parsed.apply(accepting: [1], to: source)
                == "first\nsecond\n"
        )
    }

    @Test("Deleting every line yields an empty document")
    func deleteEverything() throws {
        let source = "one\ntwo\n"
        let text = proposal(
            for: source,
            hunks: """
            @@ -1,2 +0,0 @@
            -one
            -two
            """
        )
        let parsed = try MarkdownProposal.parse(text)
        #expect(try parsed.apply(accepting: [1], to: source) == "")
    }

    @Test("A missing final newline round-trips")
    func noTrailingNewline() throws {
        let source = "alpha\nnote"
        let text = proposal(
            for: source,
            hunks: """
            @@ -1,2 +1,2 @@
             alpha
            -note
            \\ No newline at end of file
            +NOTE
            \\ No newline at end of file
            """
        )
        let parsed = try MarkdownProposal.parse(text)
        #expect(parsed.hunks[0].oldLastHasNewline == false)
        #expect(parsed.hunks[0].newLastHasNewline == false)
        #expect(
            try parsed.apply(accepting: [1], to: source)
                == "alpha\nNOTE"
        )
    }

    @Test("Adding a final newline is expressed in the hunk")
    func addingTrailingNewline() throws {
        let source = "note"
        let text = proposal(
            for: source,
            hunks: """
            @@ -1 +1 @@
            -note
            \\ No newline at end of file
            +note
            """
        )
        let parsed = try MarkdownProposal.parse(text)
        #expect(
            try parsed.apply(accepting: [1], to: source) == "note\n"
        )
    }

    @Test("The encoded form parses and applies identically")
    func encodedRoundTrip() throws {
        let source = "alpha\nnote\nbeta\n"
        let parsed = try MarkdownProposal.parse(
            proposal(
                for: source,
                hunks: """
                @@ -1,3 +1,3 @@
                 alpha
                -note
                +NOTE
                 beta
                """
            )
        )
        let roundTripped = try MarkdownProposal.parse(parsed.encoded())
        #expect(roundTripped == parsed)
        #expect(
            try roundTripped.apply(accepting: [1], to: source)
                == "alpha\nNOTE\nbeta\n"
        )
    }

    @Test("Unsupported versions and bad headers are refused")
    func malformedHeaders() {
        let source = "a\n"
        #expect(throws: MarkdownProposalError.unsupportedVersion(2)) {
            try MarkdownProposal.parse(
                """
                # sonovo-proposal 2
                # document: doc.md
                # base-sha256: \(hash(source))
                --- a/doc.md
                +++ b/doc.md
                @@ -1 +1 @@
                -a
                +b
                """
            )
        }
        #expect(throws: (any Error).self) {
            try MarkdownProposal.parse(
                """
                # sonovo-proposal 1
                # document: doc.md
                # base-sha256: not-a-hash
                --- a/doc.md
                +++ b/doc.md
                @@ -1 +1 @@
                -a
                +b
                """
            )
        }
        #expect(throws: (any Error).self) {
            try MarkdownProposal.parse(
                """
                # sonovo-proposal 1
                # document: doc.md
                # base-sha256: \(hash(source))
                --- a/doc.md
                +++ b/doc.md
                """
            )
        }
    }

    @Test("The conventional proposal path sits beside the document")
    func proposalPath() {
        let url = URL(fileURLWithPath: "/tmp/show/doc.md")
        #expect(
            MarkdownProposal.proposalURL(for: url).path
                == "/tmp/show/.doc.md.proposal.diff"
        )
    }
}
