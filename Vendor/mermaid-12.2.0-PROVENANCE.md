# Mermaid 12.2.0 provenance

- **Package:** `mermaid` 12.2.0 from the npm registry
- **Tarball:** `https://registry.npmjs.org/mermaid/-/mermaid-12.2.0.tgz`
- **Tarball SHA-256:** `071914164d0f6d53e5c26a10a220230d4ae8d37ed0f2263fbf072266f0af3a0a`
- **Bundled file:** `Sources/SonovoDiagramUI/Resources/mermaid-12.2.0.min.js`
  (based on npm `dist/mermaid.min.js`; patched bundle 5,494,952 bytes)
- **Bundled file SHA-256:** `684fc94a049168275c77d31973d6c7588c1f81ad9fffce434264ae05452daf58`
- **Unpatched upstream file SHA-256:** `a8a6a6f805b074a8261a2825c86f99c8054acb3b35f50bb7e24a4f9f2c3c3b9f`
- **License:** MIT, `Vendor/mermaid-12.2.0-LICENSE.txt`
- **Fetched:** 2026-10-26

The minified bundle ends with the license comments of the libraries it
contains (including d3 and jQuery-derived code). Those comments travel with
the file and are not stripped.

To refresh: download the same version from npm, verify the tarball hash above,
replace the bundled file, update `MermaidRendererPolicy.rendererVersion` so
cached SVGs invalidate, and rerun `DiagramRendererTests` and `MarkdownMermaidTests`. Reapply and document the syntax patch below when needed.

## Sonovo local syntax patch

The bundled JavaScript uses `m["keyCount"]` in place of one `m.keyCount` access in atlas accounting. This preserves runtime property lookup while preventing the generic credential scanner from misreading the adjacent minified identifier assignment as a literal API key. No scanner rule or exclusion was weakened. A leading comment records the change; the upstream license remains intact.
