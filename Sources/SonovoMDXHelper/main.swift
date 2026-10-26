import Foundation
import SonovoMDXKit

// One compile per process. The app starts this helper through
// `/usr/bin/sandbox-exec` with network and file writes denied; the request
// carries every source, so the helper opens nothing but the compiler script
// and its input file.
//
// Usage: SonovoMDXHelper <compiler.js> <request.json>
// Output: one JSON object on stdout. Exit 0 when a response was produced
// (including a compile diagnostic); exit 2 for a bad invocation; exit 3 when
// the bundled toolchain cannot start.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

guard CommandLine.arguments.count == 3 else {
    fail(
        "usage: SonovoMDXHelper <compiler.js> <request.json>",
        code: 2
    )
}

let compilerURL = URL(
    fileURLWithPath: CommandLine.arguments[1]
).standardizedFileURL
let requestURL = URL(
    fileURLWithPath: CommandLine.arguments[2]
).standardizedFileURL

let requestData: Data
do {
    requestData = try Data(contentsOf: requestURL)
} catch {
    fail(
        "could not read the request: \(error.localizedDescription)",
        code: 2
    )
}

let request: MDXCompileRequest
do {
    request = try JSONDecoder().decode(MDXCompileRequest.self, from: requestData)
} catch {
    fail(
        "could not decode the request: \(error.localizedDescription)",
        code: 2
    )
}

let toolchain: MDXToolchain
do {
    toolchain = try MDXToolchain(compilerScriptURL: compilerURL)
} catch {
    fail(
        "the bundled MDX compiler is unavailable: "
            + (error.localizedDescription),
        code: 3
    )
}

let response: MDXCompileResponse
do {
    response = try toolchain.compile(request)
} catch {
    fail(
        "the bundled MDX compiler failed: \(error.localizedDescription)",
        code: 3
    )
}

struct Output: Encodable {
    let ok: Bool
    let entry: String?
    let modules: [MDXCompiledModule]
    let error: String?
    let line: Int?
    let column: Int?

    init(_ response: MDXCompileResponse) {
        ok = response.ok
        entry = response.entry
        modules = response.modules
        error = response.diagnostic?.message
        line = response.diagnostic?.line
        column = response.diagnostic?.column
    }
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let output: Data
do {
    output = try encoder.encode(Output(response))
} catch {
    fail("could not encode the response: \(error.localizedDescription)", code: 3)
}

do {
    try FileHandle.standardOutput.write(contentsOf: output)
    try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
} catch {
    fail("could not write the response: \(error.localizedDescription)", code: 3)
}
exit(0)
