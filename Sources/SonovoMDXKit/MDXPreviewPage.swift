import Foundation

public struct MDXPreviewTheme: Hashable, Sendable {
    public let background: String
    public let foreground: String
    public let secondary: String
    public let accent: String

    public init(
        background: String,
        foreground: String,
        secondary: String,
        accent: String
    ) {
        self.background = background
        self.foreground = foreground
        self.secondary = secondary
        self.accent = accent
    }

    public static let light = MDXPreviewTheme(
        background: "#ffffff",
        foreground: "#1c1c1e",
        secondary: "#6e6e73",
        accent: "#0a5bd3"
    )

    public static let dark = MDXPreviewTheme(
        background: "#1c1c1e",
        foreground: "#f2f2f7",
        secondary: "#a1a1a6",
        accent: "#6cb4ff"
    )
}

/// Builds the one page a preview web view ever loads.
///
/// Every script is inline, including the React runtime and each compiled
/// module; there is no `eval` and no `new Function`, so the content security
/// policy needs no `'unsafe-eval'`. The policy allows no network, no remote
/// script, no frame, and only `data:` images and fonts. Modules run as the
/// bodies of functions that were written into the page, not as strings handed
/// to an evaluator: the module text cannot break out of its script block
/// because both `</script` and `<!--` are rewritten.
public enum MDXPreviewPage {
    public static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src 'unsafe-inline'",
        "style-src 'unsafe-inline'",
        "img-src data:",
        "font-src data:",
        "connect-src 'none'",
        "media-src 'none'",
        "frame-src 'none'",
        "child-src 'none'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'none'"
    ].joined(separator: "; ")

    public static func html(
        title: String,
        entry: String,
        modules: [MDXCompiledModule],
        runtimeScript: String,
        theme: MDXPreviewTheme
    ) -> String {
        var moduleScripts = ""
        for module in modules {
            // The id is a file name: it can contain a quote or a closing
            // script tag just as authored code can, so it takes both escapes.
            let id = escapeInlineScript(jsString(module.id))
            moduleScripts += """
            <script>__sonovoDefine(\(id), function (module, exports, require) {
            \(escapeInlineScript(module.code))
            });</script>

            """
        }
        let escapedEntry = escapeInlineScript(jsString(entry))
        return #"""
        <!DOCTYPE html>
        <html lang="und">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\#(contentSecurityPolicy)">
        <meta name="referrer" content="no-referrer">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\#(escapeHTML(title))</title>
        <style>
        :root {
          color-scheme: light dark;
          --mdx-background: \#(theme.background);
          --mdx-foreground: \#(theme.foreground);
          --mdx-secondary: \#(theme.secondary);
          --mdx-accent: \#(theme.accent);
        }
        html, body {
          margin: 0;
          padding: 0;
          background: var(--mdx-background);
          color: var(--mdx-foreground);
        }
        body {
          font: 15px/1.65 -apple-system, BlinkMacSystemFont, "Helvetica Neue",
            sans-serif;
        }
        #root {
          padding: 24px 28px 64px;
          max-width: 46rem;
          margin: 0 auto;
          overflow-wrap: break-word;
        }
        #root.mdx-error {
          white-space: pre-wrap;
          color: var(--mdx-secondary);
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 13px;
        }
        h1, h2, h3, h4, h5, h6 {
          line-height: 1.25;
          margin: 1.4em 0 0.5em;
        }
        h1 { font-size: 1.9em; }
        h2 { font-size: 1.5em; }
        h3 { font-size: 1.2em; }
        p, ul, ol, blockquote, pre, table { margin: 0.8em 0; }
        a { color: var(--mdx-accent); }
        code, pre {
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 0.9em;
        }
        pre {
          background: color-mix(in srgb, var(--mdx-foreground) 6%, transparent);
          padding: 12px 14px;
          border-radius: 8px;
          overflow-x: auto;
        }
        blockquote {
          margin-left: 0;
          padding-left: 14px;
          border-left: 3px solid color-mix(
            in srgb, var(--mdx-secondary) 40%, transparent
          );
          color: var(--mdx-secondary);
        }
        table { border-collapse: collapse; }
        th, td {
          border: 1px solid color-mix(
            in srgb, var(--mdx-secondary) 30%, transparent
          );
          padding: 6px 10px;
        }
        img { max-width: 100%; height: auto; }
        </style>
        </head>
        <body>
        <div id="root"></div>
        <script>
        \#(escapeInlineScript(runtimeScript))
        </script>
        <script>
        \#(escapeInlineScript(bootstrapScript))
        </script>
        \#(moduleScripts)<script>__sonovoStart(\#(escapedEntry));</script>
        </body>
        </html>
        """#
    }

    /// Escapes text for an HTML text node or attribute value.
    public static func escapeHTML(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    /// A JSON string literal, safe as a JavaScript expression.
    public static func jsString(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(text),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }

    /// Keeps authored text from ending the script element that carries it.
    ///
    /// `</script` is rewritten with a backslash before the slash and `<!--`
    /// with a Unicode escape for `!`. Both forms keep their string and
    /// template-literal value; the Unicode form is also a valid escape in a
    /// `/u` regular expression, where `\!` is an invalid identity escape and
    /// broke the whole module. `String.raw` sees the rewritten spelling —
    /// the alternative is the HTML parser ending the script early.
    public static func escapeInlineScript(_ code: String) -> String {
        let escapedComments = code.replacingOccurrences(
            of: "<!--",
            with: "<\\u0021--"
        )
        guard escapedComments.range(
            of: "</script",
            options: .caseInsensitive
        ) != nil else {
            return escapedComments
        }
        let closing = "</script"
        var result = ""
        result.reserveCapacity(escapedComments.count)
        var rest = Substring(escapedComments)
        while let range = rest.range(
            of: closing,
            options: .caseInsensitive
        ) {
            result += rest[rest.startIndex..<range.lowerBound]
            // Preserve the author's case for the tag name; only the slash
            // is escaped.
            result += "<\\/"
            result += rest[range].dropFirst(2)
            rest = rest[range.upperBound...]
        }
        result += rest
        return result
    }

    /// The module registry and loader. It is written before the module
    /// scripts and exposes exactly two globals: `__sonovoDefine` and
    /// `__sonovoStart`.
    public static let bootstrapScript = #"""
    (function () {
      "use strict";
      var registry = Object.create(null);
      var cache = Object.create(null);
      var extensions = [".mdx", ".jsx", ".js"];
      var runtime = {
        "react": true,
        "react/jsx-runtime": true,
        "react-dom/client": true
      };

      function showError(message) {
        var root = document.getElementById("root");
        if (!root) return;
        root.textContent = String(message);
        root.className = "mdx-error";
      }

      window.addEventListener("error", function (event) {
        showError("Runtime error: " + (event.message || "unknown"));
      });
      window.addEventListener("unhandledrejection", function (event) {
        showError("Runtime error: " + String(event.reason));
      });

      function normalize(from, specifier) {
        if (specifier.charAt(0) !== ".") {
          throw new Error("Refused package import: " + specifier);
        }
        var parts = from.split("/");
        parts.pop();
        var pieces = specifier.split("/");
        for (var i = 0; i < pieces.length; i++) {
          var piece = pieces[i];
          if (piece === "" || piece === ".") continue;
          if (piece === "..") {
            if (parts.length === 0) {
              throw new Error("Import leaves the project");
            }
            parts.pop();
            continue;
          }
          parts.push(piece);
        }
        return parts.join("/");
      }

      function isDefined(id) {
        return Object.prototype.hasOwnProperty.call(registry, id);
      }

      function resolveCandidate(base) {
        // An empty base is the project root: `./` from a root-level module
        // or `../` from a nested one that climbs back. Only a root index
        // module can satisfy it; a bare ".mdx" is not a file.
        if (base === "") {
          for (var k = 0; k < extensions.length; k++) {
            var rootIndex = "index" + extensions[k];
            if (isDefined(rootIndex)) return rootIndex;
          }
          return null;
        }
        if (isDefined(base)) return base;
        if (/\.(mdx|jsx|js)$/i.test(base)) return null;
        for (var i = 0; i < extensions.length; i++) {
          var direct = base + extensions[i];
          if (isDefined(direct)) return direct;
        }
        for (var j = 0; j < extensions.length; j++) {
          var index = base + "/index" + extensions[j];
          if (isDefined(index)) return index;
        }
        return null;
      }

      function requireModule(id) {
        // Membership, not truthiness: `./toString` must not resolve to
        // Object.prototype.toString.
        if (Object.prototype.hasOwnProperty.call(runtime, id)) {
          if (id === "react") return window.React;
          if (id === "react/jsx-runtime") return window.__sonovoJSXRuntime;
          return window.ReactDOM;
        }
        var resolved = resolveCandidate(id);
        if (!resolved) throw new Error("Module not found: " + id);
        // Membership, not truthiness: a module may export `0`, `false`,
        // `""`, or `null`.
        if (Object.prototype.hasOwnProperty.call(cache, resolved)) {
          // A circular import sees the record's current exports, not the
          // snapshot that existed when the record was created.
          return cache[resolved].exports;
        }
        var record = { exports: {} };
        cache[resolved] = record;
        var factory = registry[resolved];
        var localRequire = function (specifier) {
          if (Object.prototype.hasOwnProperty.call(runtime, specifier)) {
            return requireModule(specifier);
          }
          if (specifier.charAt(0) !== ".") {
            throw new Error("Refused package import: " + specifier);
          }
          return requireModule(normalize(resolved, specifier));
        };
        try {
          // The factory signature is (module, exports, require); Sucrase's
          // imports transform writes to `exports`, so the plain object must
          // be the second argument.
          factory(record, record.exports, localRequire);
        } catch (error) {
          // A module that threw is not initialized: a later require must
          // retry and report the failure, not return partial exports.
          delete cache[resolved];
          throw error;
        }
        return record.exports;
      }

      window.__sonovoDefine = function (id, factory) {
        registry[id] = factory;
      };

      window.__sonovoStart = function (entry) {
        try {
          var module = requireModule(entry);
          var component = module && (module.default || module.MDXContent);
          // React.memo and React.forwardRef produce objects, not functions;
          // requiring a function rejected valid compiled entries.
          var renderable = typeof component === "function"
            || (typeof component === "object" && component !== null
                && component.$$typeof !== undefined);
          if (window.React.isValidElementType) {
            renderable = window.React.isValidElementType(component);
          }
          if (!renderable) {
            throw new Error(
              "The entry document has no default component to render."
            );
          }
          var root = document.getElementById("root");
          window.ReactDOM.createRoot(root).render(
            window.React.createElement(component)
          );
        } catch (error) {
          showError(
            String(error && error.message ? error.message : error)
          );
        }
      };
    })();
    """#
}
