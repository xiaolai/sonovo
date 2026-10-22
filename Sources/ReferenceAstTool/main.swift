import Foundation
import ReferenceAst

// CLI wrapper around `ReferenceAst`. Kept separate from the library so tests
// can call the projection directly without spawning a process.
//
// Usage:
//   ReferenceAstTool <file.md>
//   ReferenceAstTool --stdin

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    FileHandle.standardError.write(
        Data("usage: ReferenceAstTool <file.md> | ReferenceAstTool --stdin\n".utf8)
    )
    exit(2)
}

do {
    let data: Data
    if arguments == ["--stdin"] {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        // Validate without stripping a leading U+FEFF: canonicalize removes
        // exactly one byte-order mark, and a BOM followed by a content
        // U+FEFF must keep that content character.
        guard let source = String(
            validating: Array(input),
            as: UTF8.self
        ) else {
            throw ReferenceAstError.unreadableInput("stdin")
        }
        data = try ReferenceAst.projection(for: source)
    } else if arguments.count == 1, !arguments[0].hasPrefix("--") {
        data = try ReferenceAst.projection(forFileAt: arguments[0])
    } else {
        // Extra paths or unsupported flags used to be ignored silently.
        usage()
    }

    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("ReferenceAstTool: \(error)\n".utf8))
    exit(1)
}
