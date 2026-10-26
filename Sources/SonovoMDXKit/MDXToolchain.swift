import Foundation
import JavaScriptCore

public enum MDXToolchainError: Error, LocalizedError, Equatable {
    case scriptUnreadable(String)
    case scriptEvaluation(String)
    case missingEntryPoint
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .scriptUnreadable(let detail):
            "The bundled MDX compiler could not be read: \(detail)"
        case .scriptEvaluation(let detail):
            "The bundled MDX compiler could not be started: \(detail)"
        case .missingEntryPoint:
            "The bundled MDX compiler does not expose its compile entry point."
        case .invalidResponse(let detail):
            "The bundled MDX compiler returned an unreadable response: \(detail)"
        }
    }
}

/// Runs the vendored `@mdx-js/mdx` compiler inside JavaScriptCore.
///
/// The bundle is plain JavaScript with no host bindings: it cannot read a
/// file, open a socket, or reach AppKit. The app only ever runs this inside
/// `SonovoMDXHelper`, a separate process; the kit is linked by that helper
/// and by tests, never called from the app process.
///
/// An instance is confined to one thread. Create it, compile, and discard it;
/// do not share it across tasks.
public final class MDXToolchain {
    /// Bumped with `Scripts/vendor-mdx.sh`; part of every cache key.
    public static let version = "mdx-3.1.1-react-19.3.1-acorn-8.15.0"

    private let context: JSContext
    private var pendingException: String?

    public init(compilerScriptURL: URL) throws {
        let script: String
        do {
            script = try String(contentsOf: compilerScriptURL, encoding: .utf8)
        } catch {
            throw MDXToolchainError.scriptUnreadable(
                error.localizedDescription
            )
        }
        guard let context = JSContext() else {
            throw MDXToolchainError.scriptEvaluation(
                "JavaScriptCore could not create a context."
            )
        }
        self.context = context

        context.exceptionHandler = { [weak self] _, exception in
            self?.pendingException = exception?.toString()
                ?? "unknown JavaScript exception"
        }
        context.evaluateScript(
            script,
            withSourceURL: compilerScriptURL
        )
        if let evaluationError = pendingException {
            pendingException = nil
            throw MDXToolchainError.scriptEvaluation(evaluationError)
        }
        let entry = context.objectForKeyedSubscript("__sonovoCompile")
        guard let entry, !entry.isUndefined, !entry.isNull else {
            throw MDXToolchainError.missingEntryPoint
        }
    }

    /// Compiles every file in the request and returns the modules the app
    /// resolves and hands to the preview page.
    public func compile(
        _ request: MDXCompileRequest
    ) throws -> MDXCompileResponse {
        let requestData = try JSONEncoder().encode(request)
        let requestJSON = String(decoding: requestData, as: UTF8.self)
        pendingException = nil
        let value = context.objectForKeyedSubscript("__sonovoCompile")?
            .call(withArguments: [requestJSON])
        if let pendingException {
            throw MDXToolchainError.scriptEvaluation(pendingException)
        }
        guard let raw = value?.toString(), !(value?.isUndefined ?? true) else {
            throw MDXToolchainError.invalidResponse("no value")
        }
        guard let data = raw.data(using: .utf8) else {
            throw MDXToolchainError.invalidResponse("not UTF-8")
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw MDXToolchainError.invalidResponse(error.localizedDescription)
        }
        guard envelope.ok else {
            return .failure(
                MDXCompileDiagnostic(
                    message: envelope.error ?? "MDX compilation failed.",
                    line: envelope.line,
                    column: envelope.column
                )
            )
        }
        return MDXCompileResponse(
            ok: true,
            entry: envelope.entry ?? request.entry,
            modules: envelope.modules ?? [],
            diagnostic: nil
        )
    }

    private struct Envelope: Decodable {
        let ok: Bool
        let entry: String?
        let modules: [MDXCompiledModule]?
        let error: String?
        let line: Int?
        let column: Int?
    }
}
