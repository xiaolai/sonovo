import Foundation

/// Maps a fenced code block's info string to the lexer language.
///
/// The viewer and the HTML export highlight the same fence, so the mapping
/// lives in one place rather than being re-derived at each renderer.
enum MarkdownFenceLanguage {
    static func language(for raw: String?) -> CodeLanguage? {
        guard let raw, !raw.isEmpty else { return nil }
        let name = raw
            .split(separator: " ", maxSplits: 1)
            .first
            .map(String.init)?
            .lowercased() ?? raw.lowercased()
        if let exact = CodeLanguage(rawValue: name) {
            return exact
        }
        switch name {
        case "js", "jsx", "javascript": return .javascript
        case "ts", "tsx", "typescript": return .typescript
        case "py", "python": return .python
        case "sh", "bash", "zsh", "shell", "console": return .shell
        case "yml": return .yaml
        case "c++": return .cpp
        case "objc", "objective-c": return .objectiveC
        case "text", "plaintext", "plain": return .plainText
        default: return CodeLanguage.language(forExtension: name)
        }
    }
}
