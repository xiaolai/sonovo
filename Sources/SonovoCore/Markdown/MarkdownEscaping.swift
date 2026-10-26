import Foundation

/// Escaping facts shared by every Markdown reader and writer.
enum MarkdownEscaping {
    /// The ASCII punctuation a backslash may escape (CommonMark §2.4).
    /// One definition keeps the label writer, the definition decoder, and
    /// future readers agreeing on what an escape is.
    static let punctuation = Set(
        "!\\\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
    )
}
