# MDX toolchain provenance

The MDX compiler and browser runtime are committed under
`Sources/Sonovo/Resources/` and packaged into the app. They are rebuilt only by
`Scripts/vendor-mdx.sh`, which needs network access and Node; neither is needed
to build, test, or run Sonovo.

## Bundled files

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `mdx-compiler-3.1.1.js` | 703,974 | `1eb6d32393693f585e3fe7ec2d09a48f3acd8e0020c5ea0e50d5150601d053c1` |
| `mdx-runtime-19.3.1.js` | 223,494 | `f3b0ea5aee86d302c59bfe2e8a38a65f42c7f27cb19446901003a44d8e812527` |

The compiler file is an esbuild IIFE bundle that exposes one global,
`__sonovoCompile(requestJSON)`. It parses each module's static ESM
dependencies and returns compiled CommonJS modules. The runtime file is an
esbuild browser bundle that exposes `React`, `ReactDOM`, and
`__sonovoJSXRuntime` as globals.

## Packages

| Package | Version | License | Tarball SHA-256 | Role |
| --- | --- | --- | --- | --- |
| `@mdx-js/mdx` | 3.1.1 | MIT | `e075dc0b89256c396a6862d67c77afb5d8d2e649fb0d7e076d56fefb69b5fae3` | Compiles MDX to JavaScript |
| `sucrase` | 3.35.1 | MIT | `fa555afbe97fb4f4866084a8838cb66ff520aa1adcd211269b2708afda4bc9bf` | JSX and ESM-to-CommonJS transform |
| `acorn` | 8.15.0 | MIT | `e46eae89bd9761f16d1d25563b837b55b4b78f3ece06ee0b9789cb2644f523b3` | Parses `.jsx`/`.js` imports exactly |
| `react` | 19.3.1 | MIT | `56936913918dcf1f7a6fe58784e79df54b18200a88655ce809cf5e9c4ef871aa` | Runtime |
| `react-dom` | 19.3.1 | MIT | `8b49975821eec6311e00d2b3f4b8337923253c876517388a33f9839c61ab262e` | Runtime |
| `esbuild` | 0.28.2 | MIT | `e045f94c235c7adc50e77ba2a579c7bec41b496b6b47c3a7845f7c1e19959a88` | Build-time bundler only; not shipped |

Copyright notices and the full MIT text for every package are in
`Vendor/mdx-toolchain-LICENSES.txt`. The React runtime bundle also retains its
own `@license` comments.

## Rebuilding

```sh
Scripts/vendor-mdx.sh
```

The script installs the pinned versions into a temporary directory, builds
both bundles with esbuild, copies them into `Sources/Sonovo/Resources/`, and
prints their SHA-256 hashes. Bump the version variables in the script and
`MDXToolchain.version` together; the version is part of every compile-cache
key.

## Runtime boundary

- The compiler runs in `SonovoMDXHelper`, a separate process started through
  `/usr/bin/sandbox-exec` with network and file writes denied.
- The app never evaluates MDX in its own process.
- The preview page is loaded with no base URL, a content security policy that
  allows only inline script/style and `data:` images/fonts, no message
  handlers, and a navigation delegate that cancels every navigation after the
  initial page.
- Local imports are resolved and read by the app before compilation. Remote
  and package imports are refused; the compiler's file map contains only
  project-relative sources it was given.
