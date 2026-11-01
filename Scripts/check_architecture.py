#!/usr/bin/env python3
"""Enforce source imports and declared direct dependencies during extraction.

The allowlist describes layer boundaries, not whatever imports happen to work
transitively in SwiftPM. The legacy Core target is an explicit compatibility
exception; extracted features cannot depend on it.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess

SHARED = {
    "SonovoFileIO", "SonovoDomainTypes", "SonovoDocumentSupport",
    "SonovoFeatureAPI", "SonovoDesignSystem", "SonovoWorkflowEngine",
    "SonovoDiagramEngine", "SonovoDiagramUI", "SonovoTextEngine",
    "SonovoMediaEngine", "SonovoMediaUI", "SonovoWebSupport", "SonovoImageSupport",
}
FEATURES = {
    "SonovoViewerFeature", "SonovoCodeFeature", "SonovoMarkdownFeature",
    "SonovoSubtitleFeature", "SonovoMDXFeature", "SonovoMediaFeature",
    "SonovoTimelineFeature", "SonovoModel3DFeature", "SonovoTerminalFeature",
}
ALLOWED = {
    "SonovoTestFixtures": set(),
    "Sonovo": SHARED | FEATURES | {"SonovoCore", "SonovoWorkspaceHost", "SonovoMarkdownEngine", "SonovoSubtitleEngine", "SonovoMDXKit", "GhosttyKit"},
    "SonovoImageSupport": {"SonovoFileIO", "SonovoDomainTypes"},
    "SonovoWebSupport": set(),
    "SonovoFileIO": set(),
    "SonovoDomainTypes": {"SonovoFileIO"},
    "SonovoDocumentSupport": {"SonovoFileIO", "SonovoDomainTypes", "SonovoTextEngine"},
    "SonovoFeatureAPI": {"SonovoDomainTypes", "SonovoFileIO", "SonovoDocumentSupport", "SonovoDesignSystem"},
    "SonovoDesignSystem": {"SonovoFileIO", "SonovoDomainTypes", "SonovoTextEngine"},
    "SonovoWorkspaceHost": {"SonovoDomainTypes", "SonovoFileIO", "SonovoDocumentSupport", "SonovoFeatureAPI", "SonovoDesignSystem"},
    "SonovoWorkflowEngine": {"SonovoDomainTypes", "SonovoFileIO"},
    "SonovoDiagramEngine": {"SonovoDomainTypes", "SonovoWorkflowEngine", "SonovoFileIO"},
    "SonovoDiagramUI": {"SonovoDocumentSupport", "SonovoDomainTypes", "SonovoDiagramEngine", "SonovoWorkflowEngine", "SonovoDesignSystem", "SonovoFileIO"},
    "SonovoTextEngine": {"SonovoFileIO", "SonovoDomainTypes"},
    "SonovoMarkdownEngine": {"SonovoFileIO", "SonovoDomainTypes", "SonovoDocumentSupport", "SonovoTextEngine", "SonovoWorkflowEngine", "SonovoDiagramEngine"},
    "SonovoSubtitleEngine": {"SonovoFileIO", "SonovoDomainTypes", "SonovoDocumentSupport", "SonovoTextEngine"},
    "SonovoMediaEngine": {"SonovoFileIO", "SonovoDomainTypes", "SonovoDocumentSupport", "SonovoSubtitleEngine"},
    "SonovoMediaUI": {"SonovoFileIO", "SonovoDomainTypes", "SonovoDocumentSupport", "SonovoDesignSystem", "SonovoMediaEngine"},
    "SonovoCore": {"SonovoFileIO", "SonovoDomainTypes", "SonovoDocumentSupport", "SonovoTextEngine", "SonovoWorkflowEngine", "SonovoDiagramEngine", "SonovoMarkdownEngine", "SonovoSubtitleEngine"},
    "SonovoMDXKit": {"SonovoFileIO"},
    "SonovoMDXHelper": {"SonovoMDXKit"},
    "ReferenceAst": set(),
    "ReferenceAstTool": {"ReferenceAst"},
}
for feature in FEATURES:
    ALLOWED[feature] = SHARED | ({"SonovoMarkdownEngine"} if feature == "SonovoMarkdownFeature" else set())
ALLOWED["SonovoSubtitleFeature"].add("SonovoSubtitleEngine")
ALLOWED["SonovoMDXFeature"].add("SonovoMDXKit")
ALLOWED["SonovoTerminalFeature"].add("GhosttyKit")

HEADLESS = {
    "SonovoTestFixtures", "SonovoFileIO", "SonovoDomainTypes", "SonovoDocumentSupport", "SonovoTextEngine",
    "SonovoWorkflowEngine", "SonovoDiagramEngine", "SonovoMarkdownEngine",
    "SonovoSubtitleEngine", "SonovoMediaEngine", "SonovoMDXKit", "SonovoCore",
}
UI_IMPORTS = {"SwiftUI", "AppKit", "WebKit", "PDFKit", "QuickLookUI"}
HOST_CONCRETE = re.compile(r"\b(?:CodeWorkspace|CodeDocument|MarkdownWorkspace|MarkdownDocument|SubtitleWorkspace|SubtitleDocument|MDXWorkspace|MDXDocument|Model3DWorkspace|Model3DDocument|TimelineWorkspace|TimelineDocument|MediaEditWorkspace|MediaEditDocument|TerminalSessionsStore|TerminalEnvironment|TmuxActionCoordinator|TmuxHygieneStore|Production|SampleContent)\b")

IMPORT = re.compile(r"(?m)^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:package|public|internal)\s+)?import\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_]\w*)")


def check_sources(root: Path, manifest: dict) -> list[str]:
    errors: list[str] = []
    targets = {t["name"]: t for t in manifest.get("targets", [])}
    # Feature component tests must remain runnable without the executable.
    # AppTests deliberately owns cross-feature/native host integration only.
    owned_tests = {feature + "Tests": feature for feature in FEATURES}
    owned_tests["SonovoDiagramUITests"] = "SonovoDiagramUI"
    if "Sonovo" in targets:
        for test, owner in owned_tests.items():
            if owner in targets and test not in targets:
                errors.append(f"missing independent component test target: {test}")
    for name, owner in owned_tests.items():
        if name not in targets:
            continue
        forbidden = {"Sonovo", "SonovoCore", "SonovoWorkspaceHost"} | (FEATURES - {owner})
        dependencies = set(targets[name].get("target_dependencies", []))
        for dependency in sorted(dependencies & forbidden):
            errors.append(f"component tests: forbidden dependency {name} -> {dependency}")
        for path in (root / "Tests" / name).rglob("*.swift"):
            for imported in IMPORT.findall(path.read_text()):
                if imported in forbidden:
                    errors.append(f"{path.relative_to(root)}: forbidden component test import {imported}")
    for name, target in targets.items():
        if target.get("type") == "test" or name not in ALLOWED:
            continue
        for dependency in target.get("target_dependencies", []):
            if (dependency in ALLOWED or dependency == "GhosttyKit") and dependency not in ALLOWED[name]:
                errors.append(f"package manifest: forbidden dependency {name} -> {dependency}")
    for directory in sorted((root / "Sources").iterdir()):
        if not directory.is_dir():
            continue
        target = directory.name
        if target not in ALLOWED:
            errors.append(f"unregistered architecture target: {target}")
            continue
        if target not in targets:
            errors.append(f"source target is missing from package manifest: {target}")
            continue
        declared = set(targets[target].get("target_dependencies", []))
        for path in sorted(directory.rglob("*.swift")):
            text = path.read_text()
            if target == "SonovoWorkspaceHost":
                # Line comments may explain legacy behavior without making it
                # a dependency. Declarations and built-in routing IDs may not.
                code = re.sub(r"//[^\n]*", "", text)
                if HOST_CONCRETE.search(code) or re.search(r'"builtin\.', code):
                    errors.append(f"{path.relative_to(root)}: concrete feature identifier in generic host")
            for module in IMPORT.findall(text):
                rel = path.relative_to(root)
                if target in HEADLESS and module in UI_IMPORTS:
                    errors.append(f"{rel}: headless target imports UI framework {module}")
                if module in ALLOWED or module.startswith("Sonovo") or module == "GhosttyKit":
                    if module not in ALLOWED[target]:
                        errors.append(f"{rel}: forbidden dependency {target} -> {module}")
                    elif module not in declared:
                        errors.append(f"{rel}: {module} must be a declared direct target dependency")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    if args.manifest:
        manifest = json.loads(args.manifest.read_text())
    else:
        result = subprocess.run(["swift", "package", "describe", "--type", "json"], cwd=root, capture_output=True, text=True)
        if result.returncode:
            print("architecture: cannot read package description")
            return result.returncode
        manifest = json.loads(result.stdout)
    errors = check_sources(root, manifest)
    if errors:
        print("\n".join(errors))
        return 1
    print("architecture: source import boundaries and direct dependencies clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
