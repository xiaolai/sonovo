# Third-party notices

Sonovo embeds third-party software. The notices below are required by their
licenses and apply to the corresponding files and binaries.

## Ghostty

- **Project:** https://github.com/ghostty-org/ghostty
- **License:** MIT
- **Copyright:** Copyright (c) 2024 Mitchell Hashimoto
- **Used as:** `Vendor/GhosttyKit.xcframework` (compiled libghostty), and the
  terminal resources under `Sources/Sonovo/Resources`.

The full license text is in `Vendor/Ghostty-LICENSE.txt`.

## Calyx

- **Project:** https://github.com/yuuichieguchi/Calyx
- **License:** MIT
- **Copyright:** Copyright (c) 2025 Yuuichi Eguchi
- **Used as:** the Swift bridge under `Sources/Sonovo/Terminal` (surface
  lifecycle, Metal layer, event translation, and IME shape), plus the
  `GhosttyKit.xcframework` packaging source and the bundled Ghostty resources.

The full license text is in `Vendor/Calyx-LICENSE.txt`.

The adapted source files carry a short attribution header pointing back to
this notice.

## SwiftMath

- **Project:** https://github.com/mgriebling/SwiftMath
- **License:** MIT
- **Copyright:** Copyright (c) 2023 Computer Inspirations
- **Used as:** the pinned Swift package (`exact: "1.7.3"`) that typesets TeX
  math into Core Graphics display lists for the reading view and export.
  No JavaScript and no network access are involved.

The MIT text is in `Vendor/SwiftMath-LICENSE.txt`. The package's
`mathFonts.bundle` is copied into the app bundle by `Scripts/package-app.sh`
and ships these font licenses: GUST Font License
(`Vendor/SwiftMath-GUST-FONT-LICENSE.txt`, Latin Modern Math), STIX/OFL
(`Vendor/SwiftMath-OFL.txt`), and a MathChat MIT notice bundled by SwiftMath
(`Vendor/SwiftMath-Fonts-LICENSE.txt`).

## Yams

- **Project:** https://github.com/jpsim/Yams
- **License:** MIT
- **Copyright:** Copyright (c) 2016 JP Simard
- **Used as:** the pinned Swift package (`exact: "6.2.2"`) that reads GitHub
  Actions workflow YAML into the job graph the code viewer charts. Yams wraps
  libyaml (`CYaml`); no system library is required and nothing is fetched at
  runtime.

The MIT text is in `Vendor/Yams-LICENSE.txt`.

## Mermaid

- **Project:** https://github.com/mermaid-js/mermaid
- **License:** MIT
- **Copyright:** Copyright (c) 2014 - 2022 Knut Sveidqvist
- **Used as:** the locally bundled renderer
  `Sources/Sonovo/Resources/mermaid-12.2.0.min.js`, inlined into an isolated
  `WKWebView` with no base URL and a content security policy that denies
  network and file access. No remote asset is loaded.

The MIT text is in `Vendor/mermaid-12.2.0-LICENSE.txt`; the exact npm version,
tarball hash, and bundled-file hash are recorded in
`Vendor/mermaid-12.2.0-PROVENANCE.md`. The minified file retains the license
comments of the libraries it bundles.

## Graphviz and Markmap

- **Graphviz wrapper:** https://github.com/mdaines/viz-js (`@viz-js/viz`
  3.31.0), MIT, Copyright (c) Michael Daines.
- **Graphviz:** https://graphviz.org, Graphviz 16.1.0 compiled to WebAssembly,
  Eclipse Public License 2.0. The wrapper also bundles Expat 2.8.5 (MIT).
- **Markmap:** https://github.com/markmap/markmap (`markmap-lib` and
  `markmap-view` 0.18.12), MIT, plus its bundled dependencies (d3 7.9.0 and
  others) under their own licenses.

Both are locally bundled and inlined into an isolated `WKWebView`:

- `Sources/Sonovo/Resources/viz-global-3.31.0.min.js`
- `Sources/Sonovo/Resources/markmap-0.18.12.min.js`

No remote asset is loaded. Exact versions and hashes are in
`Vendor/diagram-engines-PROVENANCE.md`; license texts are in
`Vendor/viz-js-3.31.0-LICENSE.txt`,
`Vendor/graphviz-16.1.0-LICENSE.txt`,
`Vendor/expat-2.8.5-LICENSE.txt`, and
`Vendor/markmap-0.18.12-LICENSES.txt`.

## MDX toolchain

- **Compiler:** https://github.com/mdx-js/mdx (`@mdx-js/mdx` 3.1.1), MIT,
  Copyright (c) 2017 Compositor, Inc. and Vercel, Inc.
- **Transforms:** https://github.com/alangpierce/sucrase (`sucrase` 3.35.1),
  MIT; https://github.com/acornjs/acorn (`acorn` 8.15.0), MIT.
- **Runtime:** https://react.dev (`react` and `react-dom` 19.3.1), MIT,
  Copyright (c) Meta Platforms, Inc. and affiliates.
- **Build only:** https://esbuild.github.io (`esbuild` 0.28.2), MIT. Not
  shipped.

The compiler and runtime are locally bundled:

- `Sources/Sonovo/Resources/mdx-compiler-3.1.1.js`
- `Sources/Sonovo/Resources/mdx-runtime-19.3.1.js`

The compiler runs only in a separate sandboxed helper process with network and
file writes denied. The runtime is inlined into an isolated `WKWebView` with no
base URL and a policy that denies network, files, frames, and evaluation. No
remote asset is loaded. Exact versions, tarball hashes, and bundled-file hashes
are in `Vendor/mdx-toolchain-PROVENANCE.md`; the MIT texts are in
`Vendor/mdx-toolchain-LICENSES.txt`.

## three.js

- **Project:** https://threejs.org
- **License:** MIT
- **Copyright:** Copyright © 2010-2026 three.js authors
- **Used as:** the vendored renderer and loaders under
  `Sources/Sonovo/Resources/ModelViewer/vendor/three`, copied at version
  0.186.1 by `Scripts/vendor-three.sh`.

The full license text is in `Vendor/three-LICENSE.txt`.
