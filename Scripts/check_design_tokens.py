#!/usr/bin/env python3
"""Reject raw visual literals in Sonovo view files.

The generated ledger lives in the documentation repository. Token definitions
live in Sources/Sonovo/Theme.swift. Generated art and the embedded HTML sample
are content renderers, not app chrome, and are exempt.

The editor is NSTextView-based, so AppKit literals are scanned with the same
rule as SwiftUI literals. A built-in self-test proves the scanner still catches
a known-bad line and still accepts a tokenized one.
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
    # AppKit visual values.
    "NSFont(",
    "NSFont.systemFont(ofSize:",
    "NSFont.monospacedSystemFont(ofSize:",
    "NSFont.monospacedDigitSystemFont(ofSize:",
    "NSFontDescriptor(",
    "NSColor(",
    "NSSize(",
    "NSParagraphStyle(",
    "NSMutableParagraphStyle(",
    # SwiftUI visual values.
    ".padding(",
    ".frame(",
    ".font(.system(size:",
    "lineWidth:",
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
    "Color(",
    "Color(nsColor:",
    "Spacer(minLength:",
    "HStack(",
    "VStack(",
    "LazyVStack(",
    "cornerRadius:",
)

LINE_PATTERNS = (
    # AppKit layout and typography values assigned on a line.
    "textContainerInset",
    "paragraphSpacing",
    "paragraphSpacingBefore",
    "headIndent",
    "tailIndent",
    "firstLineHeadIndent",
    "minimumLineHeight",
    "maximumLineHeight",
    "defaultParagraphStyle",
    "contentInsets",
    "edgeInsets",
)

NUMBER = re.compile(r"(?<![A-Za-z0-9_])[0-9]+(?:\.[0-9]+)?")

SELF_TEST_FIXTURES = (
    ("TextView.swift", "let font = NSFont.systemFont(ofSize: 13)", True),
    (
        "TextView.swift",
        "let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)",
        True,
    ),
    (
        "TextView.swift",
        "let color = NSColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)",
        True,
    ),
    ("TextView.swift", "let size = NSSize(width: 10, height: 12)", True),
    (
        "TextView.swift",
        "text.textContainerInset = NSSize(width: 10, height: 12)",
        True,
    ),
    ("TextView.swift", "style.paragraphSpacing = 8", True),
    ("TextView.swift", "style.headIndent = 14", True),
    ("TextView.swift", "style.paragraphSpacing =\n    8", True),
    (
        "TextView.swift",
        "style.paragraphSpacing = AppTheme.Spacing.small\nlet count = 8",
        False,
    ),
    (
        "TextView.swift",
        'let raw = #"""\ninside "# .padding(12)\n"""#',
        False,
    ),
    (
        "TextView.swift",
        'let raw = #"""\ninside \\#"""# .padding(12)\n"""#',
        False,
    ),
    (
        "TextView.swift",
        "style.paragraphSpacing = foo(\n    8\n)",
        True,
    ),
    (
        "TextView.swift",
        "style.paragraphSpacing\n    = 8",
        True,
    ),
    (
        "TextView.swift",
        "style.paragraphSpacing\nlet count = 8",
        False,
    ),
    ("TextView.swift", "style.paragraphSpacing == 8", False),
    (
        "TextView.swift",
        "let old = style.paragraphSpacing; let count = 8",
        False,
    ),
    ("TextView.swift", "style.paragraphSpacingExtra = 8", False),
    (
        "TextView.swift",
        "lineWidth: max(AppTheme.Spacing.small, 2)",
        True,
    ),
    (
        "TextView.swift",
        "style.paragraphSpacing = { let x = AppTheme.Spacing.small; return 8 }()",
        True,
    ),
    ("TextView.swift", ".padding(insets[0])", False),
    ("TextView.swift", ".padding([8, 16][0])", True),
    ("TextView.swift", ".padding([8][0])", True),
    ("TextView.swift", "let stroke = shape.strokeBorder(lineWidth:\n    2)", True),
    ("TextView.swift", ".font(.system(size:\n    13))", True),
    ("TextView.swift", "style.paragraphSpacing += 8", True),
    (
        "TextView.swift",
        "style.paragraphSpacing += AppTheme.Spacing.small",
        False,
    ),
    (
        "TextView.swift",
        ".frame(width: items.count > 0 ? AppTheme.Spacing.small : AppTheme.Spacing.large)",
        False,
    ),
    (
        "TextView.swift",
        "let f = NSFont.systemFont(ofSize: 12, weight: .bold)",
        True,
    ),
    (
        "TextView.swift",
        ".font(.system(size: 13,\n    weight: .bold))",
        True,
    ),
    ("TextView.swift", "let stroke = shape.strokeBorder(lineWidth: 2)", True),
    ("TextView.swift", ".font(.system(\n    size: 13\n))", True),
    ("TextView.swift", "// .padding(12)", False),
    (
        "TextView.swift",
        ".padding(AppTheme.Spacing.small /* 12 */)",
        False,
    ),
    ("TextView.swift", "let font = AppTheme.TypeScale.body", False),
    (
        "TextView.swift",
        "text.textContainerInset = AppTheme.Editor.textInset",
        False,
    ),
    ("TextView.swift", "let color = NSColor(named: .textBackgroundColor)", False),
    ("Theme.swift", "static let body: CGFloat = 13", False),
)


def call_at(text: str, start: int) -> tuple[int, str]:
    """Return the balanced call text beginning at start, and its end offset.

    `text` is already masked, so strings and comments are spaces and cannot
    contain parentheses.
    """
    depth = 0
    index = start
    while index < len(text):
        char = text[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index + 1, text[start : index + 1]
        index += 1
    return len(text), text[start:]


def line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def mask_swift(text: str) -> str:
    """Blank comments and string contents while preserving offsets.

    A number in `// .padding(12)` or inside a string is prose, not a visual
    literal. Newlines are kept so line numbers stay correct.
    """
    out = list(text)
    length = len(text)

    def blank(start: int, end: int) -> None:
        for index in range(start, min(end, length)):
            if out[index] != "\n":
                out[index] = " "

    index = 0
    while index < length:
        character = text[index]

        if character == "/" and index + 1 < length and text[index + 1] == "/":
            end = text.find("\n", index)
            end = length if end < 0 else end
            blank(index, end)
            index = end
            continue

        if character == "/" and index + 1 < length and text[index + 1] == "*":
            depth = 1
            end = index + 2
            while end < length and depth > 0:
                if text.startswith("/*", end):
                    depth += 1
                    end += 2
                elif text.startswith("*/", end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
            blank(index, end)
            index = end
            continue

        if character == "#":
            hashes = 0
            while index + hashes < length and text[index + hashes] == "#":
                hashes += 1
            if index + hashes < length and text[index + hashes] == '"':
                triple = text.startswith('"""', index + hashes)
                quotes = '"""' if triple else '"'
                terminator = quotes + "#" * hashes
                search = index + hashes + len(quotes)
                end = length
                while True:
                    found = text.find(terminator, search)
                    if found < 0:
                        break
                    escaped = (
                        hashes > 0
                        and found >= hashes + 1
                        and text[found - hashes - 1 : found]
                        == "\\" + "#" * hashes
                    )
                    if escaped:
                        search = found + len(terminator)
                        continue
                    end = found + len(terminator)
                    break
                blank(index, end)
                index = end
                continue

        if character == '"':
            triple = text.startswith('"""', index)
            delimiter = '"""' if triple else '"'
            end = index + len(delimiter)
            while end < length:
                if text.startswith(delimiter, end):
                    end += len(delimiter)
                    break
                if text[end] == "\\":
                    end += 2
                else:
                    end += 1
            blank(index, end)
            index = end
            continue

        index += 1

    return "".join(out)


def squash(text: str) -> tuple[str, list[int]]:
    """Remove whitespace and map each remaining character to its offset."""
    characters: list[str] = []
    mapping: list[int] = []
    for index, character in enumerate(text):
        if character.isspace():
            continue
        characters.append(character)
        mapping.append(index)
    return "".join(characters), mapping


def argument_end(masked: str, start: int) -> int:
    """End of one argument, respecting nested delimiters."""
    depth = 0
    index = start
    while index < len(masked):
        character = masked[index]
        if character in "([{":
            depth += 1
        elif character in ")]}":
            if depth == 0:
                return index
            depth -= 1
        elif depth == 0 and character == ",":
            return index
        index += 1
    return len(masked)


def outer_statement_end(text: str) -> int:
    """Stop at a top-level `;` or closing brace, not a nested one."""
    depth = 0
    for index, character in enumerate(text):
        if character in "([{":
            depth += 1
        elif character in ")]}":
            if depth == 0:
                return index
            depth -= 1
        elif depth == 0 and character == ";":
            return index
    return len(text)


def is_subscript(text: str, opening: int) -> bool:
    """Whether the `[` at `opening` indexes a value rather than opening a
    literal. `insets[0]`, `values()[0]`, and `rows[0][1]` are subscripts;
    `[8]`, `[8, 16]`, and `color: [8]` are literals."""
    index = opening - 1
    while index >= 0 and text[index].isspace():
        index -= 1
    if index < 0:
        return False
    previous = text[index]
    return previous.isalnum() or previous in "_)]"


def is_comparison_operand(text: str, start: int, end: int) -> bool:
    """Whether the number is part of a comparison, not a visual value.

    `.frame(width: items.count > 0 ? AppTheme.Spacing.small : ...)` must not
    fail because of the count check.
    """
    before = start - 1
    while before >= 0 and text[before].isspace():
        before -= 1
    if before >= 0 and text[before] in "<>":
        return True
    if before >= 1 and text[before - 1 : before + 1] in ("==", "!=", "<=", ">="):
        return True
    after = end
    while after < len(text) and text[after].isspace():
        after += 1
    if after < len(text) and text[after] in "<>":
        return True
    return text[after : after + 2] in ("==", "!=", "<=", ">=")


def has_visual_number(text: str) -> bool:
    """True when a number supplies a visual value.

    A number inside an array literal (`[8, 16][0]`) is visual; a
    single-expression subscript (`insets[0]`, `items[index + 1]`) is not, and
    neither is an operand of a comparison used as a condition.
    """
    for match in NUMBER.finditer(text):
        if is_comparison_operand(text, match.start(), match.end()):
            continue
        depth = 0
        opening = -1
        for index, character in enumerate(text[: match.start()]):
            if character == "[":
                depth += 1
                opening = index
            elif character == "]" and depth > 0:
                depth -= 1
        if depth > 0 and opening >= 0:
            closing = text.find("]", match.end())
            content = (
                text[opening + 1 : closing]
                if closing >= 0
                else text[opening + 1 :]
            )
            if "," not in content and is_subscript(text, opening):
                continue
        return True
    return False


def needs_continuation(text: str) -> bool:
    stripped = text.strip()
    if not stripped:
        return True
    if stripped[-1] in "=([,+-*/%&|?:.\\":
        return True
    opens = sum(text.count(character) for character in "([{")
    closes = sum(text.count(character) for character in ")]}")
    return opens > closes


def assignment_value(masked: str, after: int) -> tuple[str, int] | None:
    """Return the assigned value and its start offset, or None."""
    line_end = masked.find("\n", after)
    line_end = len(masked) if line_end < 0 else line_end
    line = masked[after:line_end]
    value_line_start = after
    equals = line.find("=")
    if equals < 0:
        # `name` on one line and `= value` on the next. Only a line that
        # starts with `=` is a continuation; an unrelated next statement is
        # not.
        if line_end >= len(masked):
            return None
        next_line_start = line_end + 1
        next_end = masked.find("\n", next_line_start)
        next_end = len(masked) if next_end < 0 else next_end
        next_line = masked[next_line_start:next_end]
        stripped = next_line.lstrip()
        if not stripped.startswith("="):
            return None
        equals = next_line.index("=")
        line_end = next_end
        line = next_line
        value_line_start = next_line_start

    # The property must be directly followed by `= value` or a compound
    # assignment (`+= value`). Comparisons and a later unrelated assignment
    # are not raw visual values.
    prefix = line[:equals].strip()
    compound_operators = {"+", "-", "*", "/", "%", "&", "|", "^", "<<", ">>"}
    if prefix:
        if prefix not in compound_operators:
            return None
    else:
        if equals + 1 < len(line) and line[equals + 1] == "=":
            return None
        if equals > 0 and line[equals - 1] in "+-*/%&|^<>!=":
            return None

    start = value_line_start + equals + 1
    pieces: list[str] = []
    cursor = start
    while True:
        end = masked.find("\n", cursor)
        end = len(masked) if end < 0 else end
        pieces.append(masked[cursor:end])
        joined = "\n".join(pieces)
        if len(joined) >= 8192:
            break
        if end >= len(masked):
            break

        next_start = end + 1
        next_end = masked.find("\n", next_start)
        next_end = len(masked) if next_end < 0 else next_end
        next_line = masked[next_start:next_end].lstrip()
        continues = bool(next_line) and next_line[0] in "+-*/%&|?:."

        if not needs_continuation(joined) and not continues:
            break
        cursor = next_start

    value = "\n".join(pieces)
    stop = outer_statement_end(value)
    return value[:stop], start


def at_identifier_boundary(text: str, offset: int, pattern: str) -> bool:
    if not pattern:
        return False
    if offset > 0:
        first = pattern[0]
        if first.isalnum() or first == "_":
            previous = text[offset - 1]
            if previous.isalnum() or previous == "_":
                return False
    last = pattern[-1]
    if last.isalnum() or last == "_":
        after = offset + len(pattern)
        if after < len(text):
            following = text[after]
            if following.isalnum() or following == "_":
                return False
    return True


def pattern_starts(
    masked: str,
    squashed: str,
    mapping: list[int],
    pattern: str,
):
    """Yield offsets where `pattern` occurs at an identifier boundary.

    Whitespace is insignificant: the pattern and the source are both
    squashed, and each hit maps back to its original offset.
    """
    pattern_squashed = re.sub(r"\s+", "", pattern)
    offset = 0
    while True:
        found = squashed.find(pattern_squashed, offset)
        if found < 0:
            return
        offset = found + 1
        start = mapping[found]
        if at_identifier_boundary(masked, start, pattern):
            yield start


def scan_text(name: str, text: str) -> list[str]:
    findings: list[str] = []
    seen: set[tuple[int, str, int]] = set()

    masked = mask_swift(text)
    squashed, mapping = squash(masked)

    def record(offset: int, fragment: str) -> None:
        display = re.sub(r"\s+", " ", fragment).strip()
        key = (line_of(text, offset), display, offset)
        if key in seen:
            return
        seen.add(key)
        findings.append(f"{name}:{key[0]}: {display}")

    for pattern in LINE_PATTERNS:
        for start in pattern_starts(masked, squashed, mapping, pattern):
            after = start + len(pattern)
            assigned = assignment_value(masked, after)
            if assigned is None:
                continue
            value, value_start = assigned
            if has_visual_number(value):
                record(start, text[start : value_start + len(value)])

    for pattern in CALL_PATTERNS:
        pattern_squashed = re.sub(r"\s+", "", pattern)
        for start in pattern_starts(masked, squashed, mapping, pattern):
            if pattern == "Color(":
                open_index = masked.find(
                    "(", start, min(len(masked), start + 160)
                )
                probe = open_index + 1 if open_index >= 0 else -1
                while 0 <= probe < len(masked) and masked[probe].isspace():
                    probe += 1
                if probe >= 0 and masked.startswith("nsColor:", probe):
                    # The dedicated always-flag pattern handles this call,
                    # even when whitespace separates `Color` from `(`.
                    continue

            # Argument-label patterns have no balanced call: inspect the
            # value up to the argument's delimiter.
            if pattern_squashed.endswith(":"):
                after = start + len(pattern)
                stop = argument_end(masked, after)
                fragment = text[start:stop]
                if pattern_squashed == "Color(nsColor:":
                    record(start, fragment)
                elif has_visual_number(masked[start:stop]):
                    record(start, fragment)
                continue

            open_index = masked.find("(", start, min(len(masked), start + 160))
            if open_index < 0:
                continue
            end, _ = call_at(masked, open_index)
            fragment = text[start:end]

            if pattern.startswith(".background(."):
                record(start, fragment)
            elif has_visual_number(masked[start:end]):
                record(start, fragment)

    return findings


def scan(path: Path) -> list[str]:
    return scan_text(str(path.relative_to(ROOT)), path.read_text())


def self_test() -> list[str]:
    failures: list[str] = []
    for name, text, should_flag in SELF_TEST_FIXTURES:
        if name in EXEMPT:
            continue
        flagged = bool(scan_text(name, text))
        if flagged != should_flag:
            expectation = "flag" if should_flag else "accept"
            failures.append(
                f"self-test {name}: expected to {expectation}: {text}"
            )

    duplicate = scan_text(
        "TextView.swift",
        "let color = NSColor(red: 1, green: 0, blue: 0, alpha: 1)",
    )
    if len(duplicate) != 1:
        failures.append(
            "self-test duplicate detection: expected 1 finding, got "
            f"{len(duplicate)}: {duplicate}"
        )

    whitespace_duplicate = scan_text(
        "TextView.swift",
        "let color = Color ( nsColor: nativeColors[0])",
    )
    if len(whitespace_duplicate) != 1:
        failures.append(
            "self-test whitespace duplicate: expected 1 finding, got "
            f"{len(whitespace_duplicate)}: {whitespace_duplicate}"
        )

    identical_calls = scan_text(
        "TextView.swift",
        "let a = Color(red: 1); let b = Color(red: 1)",
    )
    if len(identical_calls) != 2:
        failures.append(
            "self-test identical calls: expected 2 findings, got "
            f"{len(identical_calls)}: {identical_calls}"
        )
    return failures


def main() -> int:
    failures = self_test()
    if failures:
        print("design-token scanner self-test failed:", file=sys.stderr)
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1

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
        print(
            "Move the value into Sources/Sonovo/Theme.swift and reference the token.",
            file=sys.stderr,
        )
        return 1

    print("design tokens: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
