import Foundation

/// A language the code viewer can highlight and outline.
///
/// Language identity is filename and extension based only. The scanner and the
/// project search share this table so a file that is visible in the sidebar is
/// also searchable, and the reverse.
enum CodeLanguage: String, CaseIterable, Sendable {
    case swift
    case javascript
    case typescript
    case python
    case shell
    case json
    case jsonc
    case yaml
    case toml
    case xml
    case css
    case scss
    case sql
    case c
    case cpp
    case objectiveC
    case rust
    case go
    case java
    case kotlin
    case ruby
    case php
    case lua
    case makefile
    case dockerfile
    case rakefile
    case gemfile
    case plainText

    /// One extension table. `extensions` and `language(forExtension:)` are
    /// derived from it so the scanner and the viewer cannot disagree.
    private static let extensionMap: [String: CodeLanguage] = [
        "swift": .swift,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript,
        "jsx": .javascript,
        "ts": .typescript, "mts": .typescript, "cts": .typescript,
        "tsx": .typescript,
        "py": .python, "pyw": .python, "pyi": .python,
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell,
        "zshrc": .shell, "bashrc": .shell,
        "json": .json, "jsonc": .jsonc,
        "yml": .yaml, "yaml": .yaml,
        "toml": .toml,
        "xml": .xml,
        "css": .css, "scss": .scss,
        "sql": .sql,
        "c": .c, "h": .c,
        "cc": .cpp, "cpp": .cpp, "cxx": .cpp,
        "hpp": .cpp, "hh": .cpp, "hxx": .cpp,
        "m": .objectiveC, "mm": .objectiveC,
        "rs": .rust,
        "go": .go,
        "java": .java, "kt": .kotlin, "kts": .kotlin,
        "rb": .ruby,
        "php": .php,
        "lua": .lua,
        "txt": .plainText, "log": .plainText
    ]

    /// The extensions the scanner and search classify as code.
    static let extensions: Set<String> = Set(extensionMap.keys)

    private static let specialFilenameMap: [String: CodeLanguage] = [
        "Makefile": .makefile,
        "makefile": .makefile,
        "GNUmakefile": .makefile,
        "Dockerfile": .dockerfile,
        "Containerfile": .dockerfile,
        "Rakefile": .rakefile,
        "Gemfile": .gemfile,
        ".bashrc": .shell,
        ".zshrc": .shell,
        ".bash_profile": .shell,
        ".zprofile": .shell,
        ".zshenv": .shell
    ]

    /// Exact filenames that are code without an extension.
    static let specialFilenames: Set<String> = Set(
        specialFilenameMap.keys
    )

    /// Resolves the language from a filename. The name decides special files
    /// first; otherwise the lowercased extension decides.
    static func language(forFilename name: String) -> CodeLanguage? {
        if let special = specialFilenameMap[name] {
            return special
        }
        if name.hasPrefix("Dockerfile.") {
            return .dockerfile
        }
        let fileExtension = (name as NSString).pathExtension.lowercased()
        return language(forExtension: fileExtension)
    }

    static func language(for url: URL) -> CodeLanguage {
        language(forFilename: url.lastPathComponent) ?? .plainText
    }

    static func language(forExtension fileExtension: String) -> CodeLanguage? {
        extensionMap[fileExtension.lowercased()]
    }

    /// Whether the scanner should index this extension as code.
    static func isCodeExtension(_ fileExtension: String) -> Bool {
        extensions.contains(fileExtension.lowercased())
    }

    var displayName: String {
        switch self {
        case .swift: "Swift"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .python: "Python"
        case .shell: "Shell"
        case .json: "JSON"
        case .jsonc: "JSON with Comments"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .xml: "XML"
        case .css: "CSS"
        case .scss: "SCSS"
        case .sql: "SQL"
        case .c: "C"
        case .cpp: "C++"
        case .objectiveC: "Objective-C"
        case .rust: "Rust"
        case .go: "Go"
        case .java: "Java"
        case .kotlin: "Kotlin"
        case .ruby: "Ruby"
        case .php: "PHP"
        case .lua: "Lua"
        case .makefile: "Makefile"
        case .dockerfile: "Dockerfile"
        case .rakefile: "Rakefile"
        case .gemfile: "Gemfile"
        case .plainText: "Plain Text"
        }
    }

    /// The outline is limited in v1 to the four languages in the plan.
    var supportsOutline: Bool {
        switch self {
        case .swift, .javascript, .typescript, .python, .shell:
            true
        default:
            false
        }
    }

    var isPlainText: Bool { self == .plainText }

    /// The lexer specification. Blocking rules are ordered: the first match
    /// at a position wins.
    var syntax: CodeSyntaxSpec {
        switch self {
        case .swift:
            return CodeSyntaxSpec(
                lineComments: ["//"],
                blockComments: [.init(open: "/*", close: "*/", nested: true)],
                stringQuotes: ["\""],
                multilineStrings: [
                    .init(open: "\"\"\"", close: "\"\"\"")
                ],
                keywords: Self.swiftKeywords,
                typeKeywords: Self.swiftTypes
            )
        case .javascript:
            return CodeSyntaxSpec(
                lineComments: ["//"],
                blockComments: [.init(open: "/*", close: "*/", nested: false)],
                stringQuotes: ["\"", "'"],
                backtickStrings: true,
                keywords: Self.javaScriptKeywords
            )
        case .typescript:
            return CodeSyntaxSpec(
                lineComments: ["//"],
                blockComments: [.init(open: "/*", close: "*/", nested: false)],
                stringQuotes: ["\"", "'"],
                backtickStrings: true,
                keywords: Self.javaScriptKeywords
                    .union(Self.typeScriptKeywords),
                typeKeywords: Self.typeScriptTypes
            )
        case .python:
            return CodeSyntaxSpec(
                lineComments: ["#"],
                stringQuotes: ["\"", "'"],
                multilineStrings: [
                    .init(open: "\"\"\"", close: "\"\"\""),
                    .init(open: "'''", close: "'''")
                ],
                keywords: Self.pythonKeywords,
                typeKeywords: Self.pythonTypes
            )
        case .shell:
            return CodeSyntaxSpec(
                lineComments: ["#"],
                stringQuotes: ["\"", "'"],
                heredocs: [
                    .init(indentation: .exact),
                    .init(indentation: .tabs)
                ],
                keywords: Self.shellKeywords,
                singleQuoteEscapes: false,
                hashCommentRequiresBoundary: true
            )
        case .json:
            return CodeSyntaxSpec(
                stringQuotes: ["\""],
                keywords: ["true", "false", "null"]
            )
        case .jsonc:
            return CodeSyntaxSpec(
                lineComments: ["//"],
                blockComments: [.init(open: "/*", close: "*/", nested: false)],
                stringQuotes: ["\""],
                keywords: ["true", "false", "null"]
            )
        case .yaml:
            return CodeSyntaxSpec(
                lineComments: ["#"],
                stringQuotes: ["\"", "'"],
                keywords: ["true", "false", "null", "yes", "no", "on", "off"],
                singleQuoteEscapes: false,
                doubledQuoteEscapes: true
            )
        case .toml:
            return CodeSyntaxSpec(
                lineComments: ["#"],
                stringQuotes: ["\"", "'"],
                multilineStrings: [
                    .init(open: "\"\"\"", close: "\"\"\""),
                    .init(open: "'''", close: "'''", escapes: false)
                ],
                keywords: ["true", "false"],
                singleQuoteEscapes: false
            )
        case .xml:
            return CodeSyntaxSpec(
                blockComments: [.init(open: "<!--", close: "-->", nested: false)],
                stringQuotes: ["\"", "'"],
                markupTags: true
            )
        case .css:
            return CodeSyntaxSpec(
                blockComments: [.init(open: "/*", close: "*/", nested: false)],
                stringQuotes: ["\"", "'"]
            )
        case .scss:
            return CodeSyntaxSpec(
                lineComments: ["//"],
                blockComments: [.init(open: "/*", close: "*/", nested: false)],
                stringQuotes: ["\"", "'"]
            )
        case .sql:
            return CodeSyntaxSpec(
                lineComments: ["--"],
                blockComments: [.init(open: "/*", close: "*/", nested: false)],
                stringQuotes: ["'", "\""],
                keywords: Self.sqlKeywords,
                caseInsensitiveKeywords: true,
                singleQuoteEscapes: false,
                doubleQuoteEscapes: false,
                doubledQuoteEscapes: true
            )
        case .c, .objectiveC:
            return CodeSyntaxSpec(
                lineComments: ["//"],
                blockComments: [.init(open: "/*", close: "*/", nested: false)],
                stringQuotes: ["\"", "'"],
                keywords: Self.cKeywords,
                typeKeywords: Self.cTypes
            )
        case .cpp:
            return CodeSyntaxSpec(
                lineComments: ["//"],
                blockComments: [.init(open: "/*", close: "*/", nested: false)],
                stringQuotes: ["\"", "'"],
                rawStrings: .cPlusPlus,
                keywords: Self.cKeywords.union(Self.cppKeywords),
                typeKeywords: Self.cTypes
            )
        case .rust:
            return CodeSyntaxSpec(
                lineComments: ["//"],
                blockComments: [.init(open: "/*", close: "*/", nested: true)],
                stringQuotes: ["\"", "'"],
                rawStrings: .rust,
                keywords: Self.rustKeywords,
                typeKeywords: Self.rustTypes
            )
        case .go:
            return CodeSyntaxSpec(
                lineComments: ["//"],
                blockComments: [.init(open: "/*", close: "*/", nested: false)],
                stringQuotes: ["\"", "'"],
                backtickStrings: true,
                keywords: Self.goKeywords,
                typeKeywords: Self.goTypes,
                backtickEscapes: false
            )
        case .java:
            return CodeSyntaxSpec(
                lineComments: ["//"],
                blockComments: [.init(open: "/*", close: "*/", nested: false)],
                stringQuotes: ["\"", "'"],
                keywords: Self.javaKeywords,
                typeKeywords: Self.javaTypes
            )
        case .kotlin:
            return CodeSyntaxSpec(
                lineComments: ["//"],
                blockComments: [.init(open: "/*", close: "*/", nested: true)],
                stringQuotes: ["\"", "'"],
                multilineStrings: [
                    .init(
                        open: "\"\"\"",
                        close: "\"\"\"",
                        escapes: false
                    )
                ],
                keywords: Self.kotlinKeywords,
                typeKeywords: Self.javaTypes
            )
        case .ruby:
            return CodeSyntaxSpec(
                lineComments: ["#"],
                stringQuotes: ["\"", "'"],
                heredocs: [
                    .init(
                        indentation: .exact,
                        requiresAdjacentDelimiter: true
                    ),
                    .init(
                        indentation: .whitespace,
                        requiresAdjacentDelimiter: true,
                        allowsSquiggly: true
                    )
                ],
                keywords: Self.rubyKeywords
            )
        case .php:
            return CodeSyntaxSpec(
                lineComments: ["//", "#"],
                blockComments: [.init(open: "/*", close: "*/", nested: false)],
                stringQuotes: ["\"", "'"],
                keywords: Self.phpKeywords
            )
        case .lua:
            return CodeSyntaxSpec(
                lineComments: ["--"],
                blockComments: [.init(open: "--[[", close: "]]", nested: false)],
                stringQuotes: ["\"", "'"],
                keywords: Self.luaKeywords
            )
        case .makefile:
            return CodeSyntaxSpec(
                lineComments: ["#"],
                stringQuotes: ["\"", "'"],
                keywords: Self.shellKeywords,
                singleQuoteEscapes: false,
                hashCommentRequiresBoundary: true
            )
        case .dockerfile:
            return CodeSyntaxSpec(
                lineComments: ["#"],
                stringQuotes: ["\"", "'"],
                keywords: Self.dockerKeywords,
                caseInsensitiveKeywords: true,
                hashCommentRequiresBoundary: true
            )
        case .rakefile, .gemfile:
            return CodeSyntaxSpec(
                lineComments: ["#"],
                stringQuotes: ["\"", "'"],
                keywords: Self.rubyKeywords
            )
        case .plainText:
            return CodeSyntaxSpec()
        }
    }
}

/// A block comment opener and closer. `nested` is true only for languages
/// whose block comments nest; treating a non-nesting language as nesting
/// would swallow the rest of the file after `/* /* */`.
struct CodeBlockComment: Sendable, Equatable {
    let open: String
    let close: String
    let nested: Bool
}

struct CodeMultilineString: Sendable, Equatable {
    let open: String
    let close: String
    /// TOML's `'''` literal strings do not process backslash escapes.
    var escapes = true
}

enum CodeRawStringStyle: Sendable, Equatable {
    /// Rust `r"…"`, `r#"…"#`, `br##"…"##`.
    case rust
    /// C++ `R"delimiter(…)delimiter"`.
    case cPlusPlus
}

/// How much indentation the closing heredoc delimiter may carry.
enum CodeHeredocIndentation: Int, Comparable, Sendable {
    /// The delimiter must be the whole line (shell `<<`).
    case exact = 0
    /// Leading tabs are ignored (shell `<<-`).
    case tabs = 1
    /// Any leading horizontal whitespace is ignored (Ruby `<<-` and `<<~`).
    case whitespace = 2

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Whether a line closes a heredoc opened with this policy.
    func closes(_ line: String, delimiter: String) -> Bool {
        let candidate: Substring
        switch self {
        case .exact:
            candidate = line[...]
        case .tabs:
            candidate = line.drop(while: { $0 == "\t" })
        case .whitespace:
            candidate = line.drop(while: { $0 == " " || $0 == "\t" })
        }
        return candidate == Substring(delimiter)
    }
}

/// One pending heredoc terminator: the delimiter and how much indentation
/// the closing line may carry.
struct CodeHeredocTerminator: Sendable, Equatable, Hashable {
    let delimiter: String
    let indentation: CodeHeredocIndentation
}

/// Shell-style heredocs. The delimiter is found after `<<` or `<<-`; a quoted
/// delimiter disables expansion but not the matching rule.
struct CodeHeredocStyle: Sendable, Equatable {
    let indentation: CodeHeredocIndentation
    /// Ruby requires `<<IDENT` with no space; a spaced `<< value` is the
    /// shift/append operator.
    var requiresAdjacentDelimiter = false
    var allowsSquiggly = false
}

struct CodeSyntaxSpec: Sendable, Equatable {
    var lineComments: [String] = []
    var blockComments: [CodeBlockComment] = []
    var stringQuotes: Set<Character> = []
    var multilineStrings: [CodeMultilineString] = []
    var backtickStrings = false
    var rawStrings: CodeRawStringStyle?
    var heredocs: [CodeHeredocStyle] = []
    var keywords: Set<String> = []
    var typeKeywords: Set<String> = []
    var markupTags = false
    var caseInsensitiveKeywords = false
    /// Go raw backticks do not process escapes; JS template strings do.
    var backtickEscapes = true
    /// Shell and TOML single-quoted strings are literal.
    var singleQuoteEscapes = true
    var doubleQuoteEscapes = true
    /// SQL and YAML escape a quote by doubling it.
    var doubledQuoteEscapes = false
    /// Shell-family `#` starts a comment only at a word boundary.
    var hashCommentRequiresBoundary = false
}

// MARK: - Keyword tables

extension CodeLanguage {
    private static let swiftKeywords: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "borrowing",
        "break", "case", "catch", "class", "consume", "consuming", "continue",
        "convenience", "copy", "defer", "default", "deinit", "didSet", "do",
        "dynamic", "else", "enum", "extension", "fallthrough", "false",
        "fileprivate", "final", "for", "func", "get", "guard", "if", "import",
        "in", "indirect", "init", "inout", "internal", "is", "isolated", "lazy",
        "let", "macro", "mutating", "nil", "nonisolated", "nonmutating", "open",
        "operator", "optional", "override", "package", "precedencegroup",
        "private", "protocol", "public", "repeat", "required", "rethrows",
        "return", "self", "Self", "set", "some", "static", "struct", "subscript",
        "super", "switch", "throw", "throws", "true", "try", "typealias",
        "unowned", "var", "weak", "where", "while", "willSet"
    ]

    private static let swiftTypes: Set<String> = [
        "Any", "AnyObject", "Array", "Bool", "Character", "Dictionary",
        "Double", "Error", "Float", "Int", "Never", "Optional", "Result", "Set",
        "String", "UInt", "Void"
    ]

    private static let javaScriptKeywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const",
        "continue", "debugger", "default", "delete", "do", "else", "export",
        "extends", "false", "finally", "for", "function", "if", "import", "in",
        "instanceof", "let", "new", "null", "of", "return", "static", "super",
        "switch", "this", "throw", "true", "try", "typeof", "undefined", "var",
        "void", "while", "with", "yield"
    ]

    private static let typeScriptKeywords: Set<String> = [
        "abstract", "as", "declare", "enum", "implements", "infer", "interface",
        "keyof", "module", "namespace", "private", "protected", "public",
        "readonly", "satisfies", "type"
    ]

    private static let typeScriptTypes: Set<String> = [
        "any", "bigint", "boolean", "never", "number", "object", "string",
        "symbol", "unknown"
    ]

    private static let pythonKeywords: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await",
        "break", "case", "class", "continue", "def", "del", "elif", "else",
        "except", "finally", "for", "from", "global", "if", "import", "in",
        "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise",
        "return", "self", "try", "while", "with", "yield"
    ]

    private static let pythonTypes: Set<String> = [
        "bool", "bytearray", "bytes", "complex", "dict", "float", "frozenset",
        "int", "list", "memoryview", "object", "set", "str", "tuple"
    ]

    private static let shellKeywords: Set<String> = [
        "alias", "break", "case", "cd", "continue", "coproc", "declare", "do",
        "done", "echo", "elif", "else", "esac", "exit", "export", "false",
        "fi", "for", "function", "if", "in", "local", "printf", "readonly",
        "return", "select", "set", "shift", "source", "test", "then", "time",
        "trap", "true", "typeset", "unset", "until", "wait", "while"
    ]

    private static let sqlKeywords: Set<String> = [
        "add", "all", "alter", "and", "as", "asc", "begin", "between", "by",
        "case", "cast", "check", "column", "commit", "constraint", "create",
        "cross", "current", "database", "default", "delete", "desc", "distinct",
        "drop", "else", "end", "except", "exists", "foreign", "from", "full",
        "group", "having", "if", "in", "index", "inner", "insert", "intersect",
        "into", "is", "join", "key", "left", "like", "limit", "not", "null",
        "offset", "on", "or", "order", "outer", "primary", "references",
        "returning", "right", "rollback", "select", "set", "table", "then",
        "union", "unique", "update", "values", "view", "when", "where", "with"
    ]

    private static let cKeywords: Set<String> = [
        "auto", "break", "case", "const", "continue", "default", "do", "else",
        "enum", "extern", "false", "for", "goto", "if", "inline", "register",
        "restrict", "return", "sizeof", "static", "struct", "switch", "true",
        "typedef", "union", "volatile", "while"
    ]

    private static let cTypes: Set<String> = [
        "bool", "char", "double", "float", "int", "long", "short", "signed",
        "size_t", "ssize_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
        "unsigned", "void", "wchar_t", "int8_t", "int16_t", "int32_t", "int64_t"
    ]

    private static let cppKeywords: Set<String> = [
        "alignas", "alignof", "and", "asm", "catch", "class", "concept",
        "consteval", "constexpr", "constinit", "const_cast", "co_await",
        "co_return", "co_yield", "decltype", "delete", "dynamic_cast", "explicit",
        "export", "final", "friend", "mutable", "namespace", "new", "noexcept",
        "not", "nullptr", "operator", "or", "override", "private", "protected",
        "public", "reinterpret_cast", "requires", "static_assert", "static_cast",
        "template", "this", "thread_local", "throw", "try", "typeid", "typename",
        "using", "virtual", "xor"
    ]

    private static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn",
        "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
        "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
        "self", "Self", "static", "struct", "super", "trait", "true", "type",
        "unsafe", "use", "where", "while"
    ]

    private static let rustTypes: Set<String> = [
        "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize",
        "str", "String", "u8", "u16", "u32", "u64", "u128", "usize", "Vec",
        "Option", "Result"
    ]

    private static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else",
        "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
        "map", "package", "range", "return", "select", "struct", "switch",
        "type", "var"
    ]

    private static let goTypes: Set<String> = [
        "bool", "byte", "complex64", "complex128", "error", "float32", "float64",
        "int", "int8", "int16", "int32", "int64", "rune", "string", "uint",
        "uint8", "uint16", "uint32", "uint64", "uintptr", "any"
    ]

    private static let javaKeywords: Set<String> = [
        "abstract", "assert", "break", "case", "catch", "class", "continue",
        "default", "do", "else", "enum", "extends", "false", "final", "finally",
        "for", "if", "implements", "import", "instanceof", "interface", "native",
        "new", "null", "package", "private", "protected", "public", "return",
        "static", "strictfp", "super", "switch", "synchronized", "this", "throw",
        "throws", "transient", "true", "try", "volatile", "while"
    ]

    private static let javaTypes: Set<String> = [
        "boolean", "byte", "char", "double", "float", "int", "long", "short",
        "String", "Object", "List", "Map", "Set", "Integer", "Long", "Double",
        "Float", "Boolean"
    ]

    private static let kotlinKeywords: Set<String> = [
        "as", "break", "by", "catch", "class", "companion", "constructor",
        "continue", "data", "do", "else", "enum", "false", "final", "finally",
        "for", "fun", "if", "in", "init", "interface", "internal", "is",
        "lateinit", "null", "object", "open", "operator", "out", "override",
        "package", "private", "protected", "public", "return", "sealed",
        "super", "suspend", "this", "throw", "true", "try", "val", "var",
        "when", "while"
    ]

    private static let rubyKeywords: Set<String> = [
        "alias", "and", "begin", "break", "case", "class", "def", "defined?",
        "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in",
        "module", "next", "nil", "not", "or", "redo", "rescue", "retry",
        "return", "self", "super", "then", "true", "undef", "unless", "until",
        "when", "while", "yield"
    ]

    private static let phpKeywords: Set<String> = [
        "abstract", "and", "array", "as", "break", "callable", "case", "catch",
        "class", "clone", "const", "continue", "declare", "default", "do",
        "echo", "else", "elseif", "empty", "enddeclare", "endfor", "endforeach",
        "endif", "endswitch", "endwhile", "enum", "extends", "false", "final",
        "finally", "fn", "for", "foreach", "function", "global", "if",
        "implements", "include", "include_once", "instanceof", "insteadof",
        "interface", "isset", "list", "match", "namespace", "new", "null",
        "or", "print", "private", "protected", "public", "readonly", "require",
        "require_once", "return", "static", "switch", "throw", "trait", "true",
        "try", "unset", "use", "var", "while", "xor", "yield"
    ]

    private static let luaKeywords: Set<String> = [
        "and", "break", "do", "else", "elseif", "end", "false", "for",
        "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat",
        "return", "then", "true", "until", "while"
    ]

    private static let dockerKeywords: Set<String> = [
        "add", "arg", "cmd", "copy", "entrypoint", "env", "expose", "from",
        "healthcheck", "label", "maintainer", "onbuild", "run", "shell", "stopsignal",
        "user", "volume", "workdir"
    ]
}
