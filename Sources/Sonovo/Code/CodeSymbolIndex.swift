import Foundation

enum CodeSymbolKind: String, Sendable, Equatable {
    case type
    case function
    case property
    case variable

    var label: String {
        switch self {
        case .type: "Type"
        case .function: "Function"
        case .property: "Property"
        case .variable: "Variable"
        }
    }

    var symbol: String {
        switch self {
        case .type: "square.stack.3d.up"
        case .function: "function"
        case .property: "p.square"
        case .variable: "v.square"
        }
    }
}

struct CodeSymbol: Identifiable, Equatable, Sendable {
    let name: String
    let kind: CodeSymbolKind
    /// 1-based line number.
    let line: Int
    /// 1-based column of the name.
    let column: Int

    var id: String { "\(line):\(column):\(name)" }
}

/// A small, line-oriented symbol index.
///
/// v1 deliberately does not build a syntax tree. It recognizes declarations at
/// line starts, which is enough for the breadcrumb menu and Go to Symbol in
/// the four supported languages, and it never guesses for the rest. Lines
/// whose lexical state at the start is a comment or a multiline string are
/// skipped, so a declaration-looking line inside one is not a symbol.
enum CodeSymbolIndex {
    private struct Token {
        let text: String
        /// Character offset within the trimmed line.
        let offset: Int
    }

    static func symbols(
        in source: String,
        language: CodeLanguage
    ) -> [CodeSymbol] {
        guard language.supportsOutline else { return [] }
        // One lex pass gives the line states; the syntax highlighter's
        // checkpoints are the authority for whether a line is code.
        let lex = CodeSyntaxHighlighter.lex(
            text: source,
            language: language,
            revision: 0
        )
        var result: [CodeSymbol] = []
        let lines = source.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        for (index, lineSlice) in lines.enumerated() {
            if Task.isCancelled { break }
            if index < lex.lines.count,
               lex.lines[index].stateAtStart != .normal {
                continue
            }
            let line = String(lineSlice)
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("#")
                || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
                continue
            }
            let baseColumn = line.distance(
                from: line.startIndex,
                to: trimmed.startIndex
            ) + 1
            if let symbol = symbol(
                in: String(trimmed),
                line: index + 1,
                baseColumn: baseColumn,
                language: language
            ) {
                result.append(symbol)
            }
        }
        return result
    }

    /// The nearest symbol at or above a 1-based line.
    static func symbol(
        at line: Int,
        in symbols: [CodeSymbol]
    ) -> CodeSymbol? {
        symbols.last { $0.line <= line }
    }

    // MARK: - Language rules

    private static func symbol(
        in text: String,
        line: Int,
        baseColumn: Int,
        language: CodeLanguage
    ) -> CodeSymbol? {
        let tokens = tokenize(text)
        switch language {
        case .swift:
            return swiftSymbol(
                tokens: tokens,
                line: line,
                baseColumn: baseColumn
            )
        case .javascript, .typescript:
            return javaScriptSymbol(
                tokens: tokens,
                line: line,
                baseColumn: baseColumn
            )
        case .python:
            return pythonSymbol(
                tokens: tokens,
                line: line,
                baseColumn: baseColumn
            )
        case .shell:
            return shellSymbol(
                text: text,
                tokens: tokens,
                line: line,
                baseColumn: baseColumn
            )
        default:
            return nil
        }
    }

    private static let swiftModifiers: Set<String> = [
        "public", "private", "fileprivate", "internal", "open", "final",
        "static", "override", "required", "convenience", "mutating",
        "nonmutating", "lazy", "weak", "unowned", "indirect", "nonisolated",
        "isolated", "dynamic", "optional", "package"
    ]

    private static func swiftSymbol(
        tokens: [Token],
        line: Int,
        baseColumn: Int
    ) -> CodeSymbol? {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let word = identifierPrefix(token.text)
            if token.text.hasPrefix("@") {
                // `@available(iOS 17.0, *)` spans several whitespace tokens;
                // count parentheses only outside quoted strings, so a `)`
                // inside a message does not end the attribute early.
                var depth = 0
                var quote: Character?
                func scan(_ text: String) {
                    for character in text {
                        if let active = quote {
                            if character == active { quote = nil }
                            continue
                        }
                        if character == "\"" || character == "'" {
                            quote = character
                        } else if character == "(" {
                            depth += 1
                        } else if character == ")" {
                            depth -= 1
                        }
                    }
                }
                scan(token.text)
                index += 1
                while index < tokens.count, depth > 0 {
                    scan(tokens[index].text)
                    index += 1
                }
                continue
            }
            if swiftModifiers.contains(word) {
                index += 1
                continue
            }
            // `class func` / `class var` are modifiers; `class Name` is a
            // declaration.
            if word == "class", index + 1 < tokens.count,
               ["func", "var", "let"].contains(
                   identifierPrefix(tokens[index + 1].text)
               ) {
                index += 1
                continue
            }
            break
        }
        guard index < tokens.count else { return nil }
        let keyword = identifierPrefix(tokens[index].text)
        let kinds: [String: (CodeSymbolKind, Bool)] = [
            "class": (.type, true),
            "struct": (.type, true),
            "enum": (.type, true),
            "protocol": (.type, true),
            "extension": (.type, true),
            "actor": (.type, true),
            "func": (.function, true),
            "init": (.function, false),
            "deinit": (.function, false),
            "subscript": (.function, false),
            "typealias": (.type, true),
            "var": (.property, true),
            "let": (.property, true)
        ]
        guard let (kind, needsName) = kinds[keyword] else { return nil }
        if !needsName {
            return makeSymbol(
                tokens[index],
                kind: kind,
                line: line,
                baseColumn: baseColumn,
                nameOverride: keyword
            )
        }
        guard index + 1 < tokens.count else { return nil }
        return makeSymbol(
            tokens[index + 1],
            kind: kind,
            line: line,
            baseColumn: baseColumn
        )
    }

    private static let javaScriptModifiers: Set<String> = [
        "export", "default", "async", "public", "private", "protected",
        "static", "abstract", "declare", "readonly", "override"
    ]

    private static func javaScriptSymbol(
        tokens: [Token],
        line: Int,
        baseColumn: Int
    ) -> CodeSymbol? {
        var index = 0
        while index < tokens.count,
              javaScriptModifiers.contains(
                  identifierPrefix(tokens[index].text)
              ) {
            index += 1
        }
        guard index < tokens.count else { return nil }
        let keyword = identifierPrefix(tokens[index].text)
        switch keyword {
        case "function":
            guard index + 1 < tokens.count else { return nil }
            return makeSymbol(
                tokens[index + 1],
                kind: .function,
                line: line,
                baseColumn: baseColumn
            )
        case "class", "interface", "enum", "type", "namespace", "module":
            guard index + 1 < tokens.count else { return nil }
            let kind: CodeSymbolKind = keyword == "namespace"
                || keyword == "module" ? .variable : .type
            return makeSymbol(
                tokens[index + 1],
                kind: kind,
                line: line,
                baseColumn: baseColumn
            )
        case "const", "let", "var":
            guard index + 1 < tokens.count else { return nil }
            let nameToken = tokens[index + 1]
            let name = identifierPrefix(nameToken.text)
            guard !name.isEmpty else { return nil }
            let rest = nameToken.text.dropFirst(name.count)
            // `const value=1` has the initializer in the same token;
            // `let value: number = 1` has it later; `let value: number;`
            // has none. Stop at the declaration's terminator.
            var hasInitializer = rest.contains("=")
            if !hasInitializer {
                var probe = index + 2
                while probe < tokens.count {
                    let text = tokens[probe].text
                    if text.hasPrefix("=") {
                        hasInitializer = true
                        break
                    }
                    if text.hasPrefix(";") || text.hasPrefix(",") {
                        break
                    }
                    probe += 1
                }
            }
            guard hasInitializer else { return nil }
            return makeSymbol(
                nameToken,
                kind: .variable,
                line: line,
                baseColumn: baseColumn
            )
        default:
            return nil
        }
    }

    private static func pythonSymbol(
        tokens: [Token],
        line: Int,
        baseColumn: Int
    ) -> CodeSymbol? {
        guard !tokens.isEmpty else { return nil }
        if tokens.count > 1, identifierPrefix(tokens[0].text) == "def" {
            return makeSymbol(
                tokens[1],
                kind: .function,
                line: line,
                baseColumn: baseColumn
            )
        }
        if tokens.count > 2, identifierPrefix(tokens[0].text) == "async",
           identifierPrefix(tokens[1].text) == "def" {
            return makeSymbol(
                tokens[2],
                kind: .function,
                line: line,
                baseColumn: baseColumn
            )
        }
        if tokens.count > 1, identifierPrefix(tokens[0].text) == "class" {
            return makeSymbol(
                tokens[1],
                kind: .type,
                line: line,
                baseColumn: baseColumn
            )
        }
        return nil
    }

    private static func shellSymbol(
        text: String,
        tokens: [Token],
        line: Int,
        baseColumn: Int
    ) -> CodeSymbol? {
        guard !tokens.isEmpty else { return nil }
        if identifierPrefix(tokens[0].text) == "function", tokens.count > 1 {
            return makeSymbol(
                tokens[1],
                kind: .function,
                line: line,
                baseColumn: baseColumn
            )
        }
        // `name() {` with any horizontal whitespace before the parentheses.
        let name = identifierPrefix(tokens[0].text)
        guard !name.isEmpty else { return nil }
        var rest = text.dropFirst(name.count)
        rest = rest.drop(while: { $0 == " " || $0 == "\t" })
        guard rest.hasPrefix("()") else { return nil }
        return makeSymbol(
            tokens[0],
            kind: .function,
            line: line,
            baseColumn: baseColumn
        )
    }

    // MARK: - Tokens

    private static func makeSymbol(
        _ token: Token,
        kind: CodeSymbolKind,
        line: Int,
        baseColumn: Int,
        nameOverride: String? = nil
    ) -> CodeSymbol? {
        let name = nameOverride ?? identifierPrefix(token.text)
        guard !name.isEmpty else { return nil }
        return CodeSymbol(
            name: name,
            kind: kind,
            line: line,
            column: baseColumn + token.offset
        )
    }

    /// Splits on horizontal whitespace while keeping each token's character
    /// offset in the trimmed line, so the reported column is the name's.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex,
                  text[index] == " " || text[index] == "\t" {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            let start = index
            while index < text.endIndex,
                  text[index] != " " && text[index] != "\t" {
                index = text.index(after: index)
            }
            tokens.append(
                Token(
                    text: String(text[start..<index]),
                    offset: text.distance(from: text.startIndex, to: start)
                )
            )
        }
        return tokens
    }

    /// The identifier at the start of a token: `foo(`, `foo:`, and `foo<T>`
    /// all become `foo`.
    private static func identifierPrefix(_ token: String) -> String {
        String(token.prefix(while: {
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$"
        }))
    }
}
