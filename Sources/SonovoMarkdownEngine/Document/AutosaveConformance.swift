import SonovoDocumentSupport

extension MarkdownDocument: Autosaveable {
    package var hasUnresolvedConflict: Bool { conflict != nil }

    package func autosave() async throws {
        _ = try await save()
    }

    package func isClosedError(_ error: Error) -> Bool {
        (error as? DocumentError) == .closed
    }
}
