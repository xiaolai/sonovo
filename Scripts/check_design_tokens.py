#!/usr/bin/env python3
"""Reject raw visual literals in Sonovo view files.

The ledger is dev-docs/DESIGN-TOKENS.md. Token definitions live in
Sources/Sonovo/Theme.swift. Generated art and the embedded HTML sample are
content renderers, not app chrome, and are exempt.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Sources" / "Sonovo"

EXEMPT = {
    "Theme.swift",
    "CoastalSceneView.swift",
    "WaveformView.swift",
    "SampleHTML.swift",
}

CALL_PATTERNS = (
    ".padding(",
    ".frame(",
    ".font(.system(size:",
    ".cornerRadius(",
    ".lineWidth:",
    ".opacity(",
    ".tracking(",
    ".lineSpacing(",
    ".shadow(",
    ".offset(",
    ".aspectRatio(",
    ".scaleEffect(",
    ".blur(",
    ".brightness(",
    ".contrast(",
    ".saturation(",
    ".background(.bar",
    ".background(.regularMaterial",
    ".background(.ultraThinMaterial",
    ".background(.thinMaterial",
    ".background(.thickMaterial",
    ".background(.sidebar",
    "Color(red:",
    "Color(nsColor:",
    "Spacer(minLength:",
    "HStack(",
    "VStack(",
    "LazyVStack(",
    "cornerRadius:",
)

NUMBER = re.compile(r"(?<![A-Za-z0-9_])[0-9]+(?:\.[0-9]+)?")


def call_at(text: str, start: int) -> tuple[int, str]:
    """Return the balanced call text beginning at start, and its end offset."""
    depth = 0
    in_string = False
    escape = False
    index = start
    while index < len(text):
        char = text[index]
        if in_string:
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index + 1, text[start : index + 1]
        index += 1
    return len(text), text[start:]


def scan(path: Path) -> list[str]:
    text = path.read_text()
    findings: list[str] = []

    for pattern in CALL_PATTERNS:
        offset = 0
        while True:
            found = text.find(pattern, offset)
            if found < 0:
                break

            if pattern == "Color(red:" or pattern == "Color(nsColor:":
                end, fragment = call_at(text, found + pattern.index("("))
                start = found
            elif pattern == "cornerRadius:":
                end = text.find("\n", found)
                end = len(text) if end < 0 else end
                fragment = text[found:end]
                start = found
            else:
                open_index = found + pattern.index("(")
                end, fragment = call_at(text, open_index)
                start = found

            if pattern.startswith(".background(."):
                findings.append(f"{path.relative_to(ROOT)}:{text.count(chr(10), 0, start) + 1}: {fragment}")
            elif pattern == "Color(nsColor:":
                findings.append(f"{path.relative_to(ROOT)}:{text.count(chr(10), 0, start) + 1}: {fragment}")
            elif NUMBER.search(fragment):
                findings.append(f"{path.relative_to(ROOT)}:{text.count(chr(10), 0, start) + 1}: {fragment}")

            offset = max(end, found + 1)

    return findings


def main() -> int:
    files = sorted(SOURCE.rglob("*.swift"))
    findings: list[str] = []
    for path in files:
        if path.name in EXEMPT:
            continue
        findings.extend(scan(path))

    if findings:
        print("Raw visual literals found outside the token ledger:", file=sys.stderr)
        for finding in findings:
            print(finding, file=sys.stderr)
        print(file=sys.stderr)
        print("Move the value into Sources/Sonovo/Theme.swift and reference the token.", file=sys.stderr)
        return 1

    print("design tokens: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
