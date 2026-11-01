#!/usr/bin/env python3
"""Create deterministic, synthetic dedicated-Mac acceptance fixtures."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import struct
import zlib


def png(path: Path, alternate: bool):
    width, height = 1200, 900
    rows = []
    for y in range(height):
        row = bytearray(b"\0")
        for x in range(width):
            band = ((x // 100) + (y // 100)) % 2
            row.extend((235, 165, 60, 255) if alternate and band else (45, 105, 180, 255) if band else (225, 235, 245, 255))
        rows.append(row)
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b""))


def pdf(path: Path):
    streams = [f"BT /F1 24 Tf 60 700 Td (Modular acceptance page {n}) Tj ET".encode() for n in [1, 2]]
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>"]
    for index, content in enumerate(streams):
        objects += [f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /Font << /F1 7 0 R >> >> /Contents {4 + index * 2} 0 R >>".encode(),
                    f"<< /Length {len(content)} >>\nstream\n".encode() + content + b"\nendstream"]
    objects.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    data = bytearray(b"%PDF-1.4\n"); offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(data)); data.extend(f"{index} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(data)
    data.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]: data.extend(f"{offset:010d} 00000 n \n".encode())
    data.extend(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    path.write_bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    root = args.root.expanduser().resolve()
    if root.name != "e2e": raise SystemExit("expected an explicit e2e directory")
    marker = root / ".sonovo-modular-e2e"
    if root.exists() and (not marker.exists() or marker.read_text() != "synthetic-only\n"):
        raise SystemExit("refusing an unmarked existing directory")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root.chmod(0o700); marker.write_text("synthetic-only\n")
    a, b = root / "modular-a", root / "modular-b"
    # These two directories are synthetic fixture outputs under the marker.
    # Reset prior generated takes/timelines so every acceptance starts alike.
    for project in (a, b):
        if project.is_symlink(): raise SystemExit("refusing a symlink fixture project")
        if project.exists(): shutil.rmtree(project)
        project.mkdir()
    (root / "tmux").mkdir(exist_ok=True)
    (a / "Reader.md").write_text("""# Modular acceptance

The actual packaged reader renders **text**, mathematics, and diagrams.

$$E = mc^2$$

```mermaid
flowchart LR
    File --> Feature --> Host
```

```dot
digraph { source -> renderer -> view }
```

```yaml
on: push
jobs:
  build:
    runs-on: macos-latest
  test:
    needs: build
    runs-on: macos-latest
```
""")
    (a / "Code.swift").write_bytes(b"\xef\xbb\xbf" + b"// Modular acceptance\r\nstruct Fixture {\r\n    let value = 42\r\n}\r\n")
    (b / "Second.swift").write_text("struct SecondProject { let value = 2 }\n")
    png(a / "image-a.png", False); png(a / "image-b.png", True); pdf(a / "Document.pdf")
    (a / "Preview.html").write_text('<!doctype html><html><head><link rel="stylesheet" href="style.css"></head><body><h1>Local HTML acceptance</h1><p>Bundled modular viewer.</p><img src="image-a.png" width="400"></body></html>')
    (a / "style.css").write_text("body { font: 22px system-ui; padding: 32px; color: #194b7d; }\n")
    (a / "Notes.rtf").write_text(r"{\rtf1\ansi\deff0 {\fonttbl {\f0 Helvetica;}}\f0\fs36 Modular Quick Look acceptance.}")
    (a / "Triangle.obj").write_text("o ModularTriangle\nv -1 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n")
    (a / "Component.mdx").write_text("# MDX acceptance\n\n<div>Packaged helper preview.</div>\n")
    (a / "Captions.srt").write_text("1\n00:00:00,000 --> 00:00:02,000\nModular acceptance.\n\n2\n00:00:03,000 --> 00:00:05,000\nSecond cue.\n")
    fixtures = Path(__file__).resolve().parents[1] / "Tests/SonovoTestFixtures/Fixtures"
    shutil.copyfile(fixtures / "vo-take-02.wav", a / "voice.wav")
    shutil.copyfile(fixtures / "long.mov", a / "Movie.mov")
    hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(a.iterdir()) if p.is_file()}
    (root / "source-hashes.json").write_text(json.dumps(hashes, indent=2) + "\n")
    print("created synthetic acceptance fixtures")


if __name__ == "__main__": main()
