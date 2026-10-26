import Foundation

/// One compile request. `entry` and every key in `files` are project-relative
/// POSIX paths; the compiler never receives absolute paths and never reads a
/// file itself.
public struct MDXCompileRequest: Codable, Hashable, Sendable {
    public let entry: String
    public let files: [String: String]

    public init(entry: String, files: [String: String]) {
        self.entry = entry
        self.files = files
    }
}

/// One module the compiler produced. `imports` are the module's static ESM
/// dependencies, parsed from the source; the app resolves them before the
/// module is ever handed to a web view.
public struct MDXCompiledModule: Codable, Hashable, Sendable {
    public let id: String
    public let code: String
    public let imports: [String]

    public init(id: String, code: String, imports: [String] = []) {
        self.id = id
        self.code = code
        self.imports = imports
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case code
        case imports
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        code = try container.decode(String.self, forKey: .code)
        imports = try container.decodeIfPresent(
            [String].self,
            forKey: .imports
        ) ?? []
    }
}

/// A compile failure with the source position the compiler reported.
public struct MDXCompileDiagnostic: Codable, Hashable, Sendable {
    public let message: String
    public let line: Int?
    public let column: Int?

    public init(message: String, line: Int? = nil, column: Int? = nil) {
        self.message = message
        self.line = line
        self.column = column
    }

    /// `line:column — message`, with the position only when it is known.
    public var displayText: String {
        guard let line else { return message }
        guard let column else { return "Line \(line): \(message)" }
        return "Line \(line):\(column): \(message)"
    }
}

/// What one compile produced: either every module, or one diagnostic.
public struct MDXCompileResponse: Hashable, Sendable {
    public let ok: Bool
    public let entry: String?
    public let modules: [MDXCompiledModule]
    public let diagnostic: MDXCompileDiagnostic?

    public init(
        ok: Bool,
        entry: String?,
        modules: [MDXCompiledModule],
        diagnostic: MDXCompileDiagnostic?
    ) {
        self.ok = ok
        self.entry = entry
        self.modules = modules
        self.diagnostic = diagnostic
    }

    public static func failure(
        _ diagnostic: MDXCompileDiagnostic
    ) -> MDXCompileResponse {
        MDXCompileResponse(
            ok: false,
            entry: nil,
            modules: [],
            diagnostic: diagnostic
        )
    }
}
