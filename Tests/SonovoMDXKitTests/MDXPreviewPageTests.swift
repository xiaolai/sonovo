import Foundation
import Testing
@testable import SonovoMDXKit

@Suite("MDX preview page")
struct MDXPreviewPageTests {
    private func page(
        modules: [MDXCompiledModule],
        title: String = "Doc"
    ) -> String {
        MDXPreviewPage.html(
            title: title,
            entry: "docs/entry.mdx",
            modules: modules,
            runtimeScript: "globalThis.React = {};",
            theme: .light
        )
    }

    @Test("The policy denies network, frames, files, and evaluation")
    func policy() {
        let csp = MDXPreviewPage.contentSecurityPolicy
        #expect(csp.contains("default-src 'none'"))
        #expect(csp.contains("script-src 'unsafe-inline'"))
        #expect(csp.contains("connect-src 'none'"))
        #expect(csp.contains("img-src data:"))
        #expect(csp.contains("frame-src 'none'"))
        #expect(csp.contains("object-src 'none'"))
        #expect(csp.contains("base-uri 'none'"))
        #expect(!csp.contains("unsafe-eval"))
        #expect(!csp.contains("http"))
    }

    @Test("The page embeds the runtime, the modules, and the entry call")
    func structure() {
        let html = page(
            modules: [
                MDXCompiledModule(
                    id: "docs/entry.mdx",
                    code: "exports.default = function () { return null; };"
                ),
                MDXCompiledModule(
                    id: "docs/Button.jsx",
                    code: "exports.default = function () { return null; };"
                )
            ]
        )
        #expect(html.contains("Content-Security-Policy"))
        #expect(html.contains("globalThis.React = {};"))
        #expect(html.contains("__sonovoDefine(\"docs/entry.mdx\""))
        #expect(html.contains("__sonovoDefine(\"docs/Button.jsx\""))
        #expect(html.contains("__sonovoStart(\"docs/entry.mdx\")"))
        #expect(html.contains("<div id=\"root\"></div>"))
    }

    @Test("The loader uses no evaluator")
    func noEval() {
        let bootstrap = MDXPreviewPage.bootstrapScript
        #expect(!bootstrap.contains("eval("))
        #expect(!bootstrap.contains("new Function"))
        #expect(bootstrap.contains("__sonovoDefine"))
        #expect(bootstrap.contains("Refused package import"))
    }

    @Test("A closing script tag in authored code cannot end its block")
    func scriptBreakout() {
        let hostile = """
        exports.default = function () {
          return "</script><script>alert(1)</script>";
        };
        """
        let html = page(
            modules: [MDXCompiledModule(id: "docs/entry.mdx", code: hostile)]
        )
        #expect(!html.contains("</script><script>alert(1)"))
        #expect(html.contains("<\\/script>"))
        // One close for the runtime, one for the bootstrap, one for the
        // module, and one for the start call.
        #expect(html.components(separatedBy: "</script>").count - 1 == 4)
    }

    @Test("An HTML comment opener is escaped inside a module")
    func commentBreakout() {
        let html = page(
            modules: [
                MDXCompiledModule(
                    id: "docs/entry.mdx",
                    code: "const a = 1; <!-- const b = 2;"
                )
            ]
        )
        #expect(html.contains("<\\u0021-- const b = 2;"))
        // The escape must also be valid where a backslash would not be:
        // `/!--/u` accepts `!`, while `\!` is an invalid identity
        // escape and would break the module.
        #expect(
            MDXPreviewPage.escapeInlineScript("const r = /<!--/u;")
                == "const r = /<\\u0021--/u;"
        )
    }

    @Test("Text is escaped for HTML and JavaScript")
    func escaping() {
        #expect(
            MDXPreviewPage.escapeHTML("<a href=\"x\">&'</a>")
                == "&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;"
        )
        #expect(MDXPreviewPage.jsString("a\"b") == "\"a\\\"b\"")
        #expect(MDXPreviewPage.jsString("a\nb") == "\"a\\nb\"")
        let html = MDXPreviewPage.html(
            title: "<Title>",
            entry: "entry.mdx",
            modules: [],
            runtimeScript: "",
            theme: .dark
        )
        #expect(html.contains("<title>&lt;Title&gt;</title>"))
        #expect(html.contains("#1c1c1e"))
    }

    @Test("The author's casing survives script escaping")
    func scriptCasing() {
        let escaped = MDXPreviewPage.escapeInlineScript("x</SCRIPT>y")
        #expect(escaped == "x<\\/SCRIPT>y")
    }
}
