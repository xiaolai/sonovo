"""Shared design-token rule surface.

The checker and the ledger generator both read this table, so the set of
content renderers cannot drift between what is enforced and what is
documented.
"""

from __future__ import annotations

# Files that render content rather than chrome. Their geometry and algorithm
# parameters are not design tokens.
CONTENT_RENDERERS: tuple[tuple[str, str], ...] = (
    (
        "Sources/Sonovo/CoastalSceneView.swift",
        "procedural scene artwork",
    ),
    (
        "Sources/Sonovo/Media/MediaWaveformView.swift",
        "media waveform geometry and amplitude",
    ),
    (
        "Sources/Sonovo/Media/Editing/MediaSelectionWaveformView.swift",
        "trim selection waveform geometry and timeline hit testing",
    ),
    (
        "Sources/Sonovo/SampleHTML.swift",
        "the embedded storyboard document",
    ),
)
