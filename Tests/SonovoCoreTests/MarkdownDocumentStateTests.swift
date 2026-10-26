import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown document state")
@MainActor
struct MarkdownDocumentStateTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test("A save the reader could never reopen is refused")
    func lineCapOnSave() throws {
        let document = MarkdownDocument(untitledWith: MarkdownFileStore())
        let tooMany = String(
            repeating: "\n",
            count: MarkdownLimits.maxSourceLines + 1
        )
        #expect(throws: DocumentError.editTooLarge) {
            try document.replaceSource(tooMany)
        }
        #expect(document.source.isEmpty)

        let atCap = String(
            repeating: "\n",
            count: MarkdownLimits.maxSourceLines
        )
        try document.replaceSource(atCap)
        #expect(document.source.utf8.count == atCap.utf8.count)
    }

    @Test("Live growth past the editable threshold stays editable")
    func liveGrowth() throws {
        let document = MarkdownDocument(untitledWith: MarkdownFileStore())
        let big = String(
            repeating: "a",
            count: MarkdownLimits.maxEditableDocumentBytes + 1
        )
        try document.replaceSource(big)
        #expect(document.isLarge)
        #expect(!document.isReadOnly)
        #expect(document.forcedSourceReason == .largeBuffer)
        #expect(document.isDirty)

        try document.replaceSource("small")
        #expect(!document.isLarge)
        #expect(!document.isReadOnly)
        #expect(document.forcedSourceReason == nil)
    }

    @Test("Growth past the read cap is refused without losing the buffer")
    func growthPastReadCap() throws {
        let document = MarkdownDocument(untitledWith: MarkdownFileStore())
        try document.replaceSource(String(repeating: "a", count: 1024))
        let tooBig = String(
            repeating: "a",
            count: MarkdownLimits.maxReadBytes + 1
        )
        #expect(throws: DocumentError.editTooLarge) {
            try document.replaceSource(tooBig)
        }
        #expect(document.source.count == 1024)
        #expect(!document.isReadOnly)
    }

    @Test("A nesting refusal clears on a successful parse")
    func nestingReason() throws {
        let document = MarkdownDocument(untitledWith: MarkdownFileStore())
        document.setNestingLimit(true)
        #expect(document.forcedSourceReason == .nestingLimit)
        document.setNestingLimit(false)
        #expect(document.forcedSourceReason == nil)

        let big = String(
            repeating: "a",
            count: MarkdownLimits.maxEditableDocumentBytes + 1
        )
        try document.replaceSource(big)
        document.setNestingLimit(true)
        #expect(document.forcedSourceReason == .nestingLimit)
        document.setNestingLimit(false)
        #expect(document.forcedSourceReason == .largeBuffer)
    }

    @Test("A large file opens read-only with a visible reason")
    func largeFileAdmission() throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("large.md")
        let data = Data(
            repeating: 0x61,
            count: MarkdownLimits.maxEditableDocumentBytes + 1
        )
        try data.write(to: url)
        let document = try MarkdownDocument(loading: url)
        #expect(document.isLarge)
        #expect(document.isReadOnly)
        #expect(document.forcedSourceReason == .large)
    }

    @Test("Disk state is explicit")
    func diskState() throws {
        let document = MarkdownDocument(untitledWith: MarkdownFileStore())
        #expect(document.diskState == .readable)
        document.setDiskState(.tooLarge)
        #expect(document.diskState == .tooLarge)
        document.setDiskState(.unreadable("permission denied"))
        #expect(document.diskState == .unreadable("permission denied"))
    }
}
