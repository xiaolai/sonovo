# Graphviz and Markmap provenance

## Graphviz

- **Wrapper:** `@viz-js/viz` 3.31.0 (MIT, Copyright (c) Michael Daines)
- **Engine:** Graphviz 16.1.0 compiled to WebAssembly, with Expat 2.8.5
- **Tarball:** `https://registry.npmjs.org/@viz-js/viz/-/viz-3.31.0.tgz`
- **Tarball SHA-256:** `7dc0189874849cca2fed7cbe88bf334cd0e6e012db16657794a812ad6f2b8c70`
- **Bundled file:** `Sources/Sonovo/Resources/viz-global-3.31.0.min.js`
  (npm `dist/viz-global.js`, 1,329,882 bytes)
- **File SHA-256:** `c9e0b310f9883910e01c66054b48b7ff4be3d8695141116635e72b0af152692e`
- **Licenses:** `Vendor/viz-js-3.31.0-LICENSE.txt`,
  `Vendor/graphviz-16.1.0-LICENSE.txt` (EPL-2.0),
  `Vendor/expat-2.8.5-LICENSE.txt` (MIT)
- **Fetched:** 2026-10-26

The global build embeds its WebAssembly module; the page compiles it with
`script-src 'wasm-unsafe-eval'` and no `'unsafe-eval'`.

## Markmap

- **Packages:** `markmap-lib` 0.18.12, `markmap-view` 0.18.12, `d3` 7.9.0
- **Bundler:** esbuild 0.28.2, IIFE, minified
- **Bundled file:** `Sources/Sonovo/Resources/markmap-0.18.12.min.js`
  (778,488 bytes)
- **File SHA-256:** `9055cf0c9847f32f91855674dc3ac5c932da233e5ec3c066575a91dd29aba25b`
- **Licenses:** `Vendor/markmap-0.18.12-LICENSES.txt` (83 bundled packages)
- **Built:** 2026-10-26

`markmap-lib` runs with an empty plugin list, so no external asset loader is
reachable. The bundle converts Markmap's HTML labels into SVG `<text>` before
returning, which keeps `foreignObject` out of the sanitized output.

To refresh: update the versions in `Scripts/vendor-diagrams.sh`, run it, update
the hashes here and in the license files, bump `DiagramRendererPolicy.version`,
and rerun the diagram tests.
