# Vendored dependencies

## GhosttyKit.xcframework

- **Engine:** [Ghostty](https://github.com/ghostty-org/ghostty), MIT.
- **Packaging source:** the arm64 XCFramework published in
  [Calyx](https://github.com/yuuichieguchi/Calyx) 0.49.0, MIT.
- **Contents:** `macos-arm64/libghostty-fat.a`, the `ghostty.h` umbrella header,
  and the `GhosttyKit` module map.
- **Size:** approximately 135 MB on disk; the static archive is about 141 MB.
- **Platform:** macOS arm64 only.

The upstream XCFramework was produced from a Ghostty checkout with:

```sh
zig build -Demit-xcframework=true -Dxcframework-target=native \
  -Demit-macos-app=false -Doptimize=ReleaseFast
```

The framework is vendored so local builds do not need Zig. Because of its size,
store it with Git LFS or fetch it before committing. The Swift bridge in
`Sources/Sonovo/Terminal` is adapted from Calyx and carries the MIT notices in
its source headers.

The bundled `ghostty` and `terminfo` resources in
`Sources/Sonovo/Resources` come from the same Calyx distribution and provide
the terminfo entries and shell-integration scripts Ghostty expects.
