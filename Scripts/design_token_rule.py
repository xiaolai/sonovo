"""Shared design-token rule surface.

The checker and the ledger generator both read this table, so the set of
content renderers cannot drift between what is enforced and what is
documented.
"""

from __future__ import annotations

from pathlib import Path
import re

# One list for the scanner, its self-tests and the generated ledger. Existing
# configured targets must contain Swift; future targets become active on move.
UI_TARGETS = (
    "Sonovo", "SonovoDesignSystem", "SonovoFeatureAPI", "SonovoWorkspaceHost",
    "SonovoImageSupport", "SonovoWebSupport", "SonovoDiagramUI", "SonovoViewerFeature", "SonovoCodeFeature",
    "SonovoMarkdownFeature", "SonovoSubtitleFeature", "SonovoMDXFeature",
    "SonovoMediaUI", "SonovoMediaFeature", "SonovoTimelineFeature", "SonovoModel3DFeature",
    "SonovoTerminalFeature",
)


def theme_path(root: Path) -> Path:
    candidates = [root / "Sources" / name / "Theme.swift" for name in UI_TARGETS]
    found = [p for p in candidates if p.is_file()]
    if len(found) != 1:
        raise ValueError("expected exactly one Theme.swift in configured UI targets")
    return found[0]


def ui_source_files(root: Path) -> list[Path]:
    sources = root / "Sources"
    files: list[Path] = []
    for directory in sorted(sources.iterdir()) if sources.exists() else []:
        if not directory.is_dir():
            continue
        swift = sorted(directory.rglob("*.swift"))
        if directory.name in UI_TARGETS:
            if not swift:
                raise ValueError(f"configured UI target is empty: {directory.name}")
            files.extend(swift)
        elif any(re.search(r"^\s*(?:(?:@\w+|package|public|internal)\s+)*import\s+(?:SwiftUI|AppKit)\b", p.read_text(), re.M) for p in swift):
            raise ValueError(f"UI target is missing from token policy: {directory.name}")
    if not files:
        raise ValueError("no populated UI targets found")
    return files

# Files that render content rather than chrome. Their geometry and algorithm
# parameters are not design tokens.
CONTENT_RENDERERS: tuple[tuple[str, str], ...] = (
    (
        "Sources/Sonovo/CoastalSceneView.swift",
        "procedural scene artwork",
    ),
    (
        "Sources/SonovoMediaFeature/MediaWaveformView.swift",
        "media waveform geometry and amplitude",
    ),
    (
        "Sources/SonovoMediaFeature/Editing/MediaSelectionWaveformView.swift",
        "trim selection waveform geometry and timeline hit testing",
    ),
    (
        "Sources/Sonovo/SampleHTML.swift",
        "the embedded storyboard document",
    ),
)
