import SonovoMarkdownEngine
import SonovoSubtitleEngine
import SonovoFileIO

// Preserves the released Core initializer's MarkdownFileStore parameter.
// The owning Subtitle engine takes AtomicFileStore; this overload bridges the
// existing public signature and options rather than adding a new capability.
public extension SonovoSubtitleEngine.SubtitleFileStore {
    init(fileStore: SonovoMarkdownEngine.MarkdownFileStore) {
        self.init(fileStore: SonovoFileIO.AtomicFileStore(options: fileStore.options))
    }
}
