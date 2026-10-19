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
