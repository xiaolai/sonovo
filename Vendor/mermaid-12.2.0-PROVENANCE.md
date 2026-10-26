# Mermaid 12.2.0 provenance

- **Package:** `mermaid` 12.2.0 from the npm registry
- **Tarball:** `https://registry.npmjs.org/mermaid/-/mermaid-12.2.0.tgz`
- **Tarball SHA-256:** `071914164d0f6d53e5c26a10a220230d4ae8d37ed0f2263fbf072266f0af3a0a`
- **Bundled file:** `Sources/Sonovo/Resources/mermaid-12.2.0.min.js`
  (npm `dist/mermaid.min.js`, 5,494,801 bytes)
- **File SHA-256:** `a8a6a6f805b074a8261a2825c86f99c8054acb3b35f50bb7e24a4f9f2c3c3b9f`
- **License:** MIT, `Vendor/mermaid-12.2.0-LICENSE.txt`
- **Fetched:** 2026-10-26

The minified bundle ends with the license comments of the libraries it
contains (including d3 and jQuery-derived code). Those comments travel with
the file and are not stripped.

To refresh: download the same version from npm, verify the tarball hash above,
replace the bundled file, update `MermaidRendererPolicy.rendererVersion` so
cached SVGs invalidate, and rerun `MarkdownMermaidTests`.
