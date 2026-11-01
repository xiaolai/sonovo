#!/usr/bin/env python3
"""Stage only resource bundles reachable from production package products.

Evaluate resolved package manifests without building targets. Stale bundles and
unreachable test-support libraries must never enter an app simply because they
remain in Products after a module move.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess


class ResourceStagingError(RuntimeError):
    pass


def resolved_manifest(root: Path) -> dict:
    def package_json(path: Path, *arguments: str) -> dict:
        result = subprocess.run(["swift", "package", "--package-path", str(path), *arguments],
                                capture_output=True, text=True)
        if result.returncode:
            raise ResourceStagingError("cannot evaluate package metadata: " + result.stderr.strip())
        return json.loads(result.stdout)

    manifest = package_json(root, "dump-package")
    graph = package_json(root, "show-dependencies", "--format", "json")
    dependencies: dict[str, dict] = {}

    def visit(node: dict) -> None:
        for child in node.get("dependencies", []):
            identity = child["identity"]
            if identity in dependencies:
                continue
            dependencies[identity] = {"identity": identity, "manifest": package_json(Path(child["path"]), "dump-package")}
            visit(child)

    visit(graph)
    manifest["_dependency_manifests"] = list(dependencies.values())
    return manifest


def required_bundles(manifest: dict) -> set[str]:
    packages = {"@root": manifest}
    packages.update({item["identity"]: item["manifest"] for item in manifest.get("_dependency_manifests", [])})
    targets = {identity: {t["name"]: t for t in package.get("targets", [])} for identity, package in packages.items()}
    products = {identity: {p["name"]: p.get("targets", []) for p in package.get("products", [])}
                for identity, package in packages.items()}
    pending: list[tuple[str, str]] = []
    if "products" in manifest:
        pending = [("@root", target) for names in products["@root"].values() for target in names]
    else:
        # Synthetic single-package fixtures may omit product metadata.
        pending = [("@root", t["name"]) for t in manifest.get("targets", []) if t.get("type") != "test"]
    seen: set[tuple[str, str]] = set()
    result: set[str] = set()

    def add_product(name: str, requested_package: str | None = None) -> None:
        candidates = [identity for identity in packages if name in products[identity]
                      and (requested_package is None or requested_package.lower() in
                           {identity.lower(), packages[identity]["name"].lower()})]
        if len(candidates) != 1:
            raise ResourceStagingError(f"resource graph cannot uniquely resolve product {name}")
        identity = candidates[0]
        pending.extend((identity, target) for target in products[identity][name])

    while pending:
        identity, name = pending.pop()
        if (identity, name) in seen:
            continue
        seen.add((identity, name))
        target = targets.get(identity, {}).get(name)
        if target is None or target.get("type") == "test":
            raise ResourceStagingError(f"invalid production resource dependency: {identity}/{name}")
        if target.get("resources"):
            # SwiftPM uses C99-mangled package/target names for bundle products.
            package_name = re.sub(r"[^A-Za-z0-9_]", "_", packages[identity]["name"])
            target_name = re.sub(r"[^A-Za-z0-9_]", "_", name)
            result.add(f"{package_name}_{target_name}.bundle")
        for dependency in target.get("dependencies", []):
            if "target" in dependency:
                pending.append((identity, dependency["target"][0]))
            elif "byName" in dependency:
                dependency_name = dependency["byName"][0]
                if dependency_name in targets[identity]:
                    pending.append((identity, dependency_name))
                else:
                    add_product(dependency_name)
            elif "product" in dependency:
                values = dependency["product"]
                add_product(values[0], values[1])
        # Also support package-describe fixtures and older metadata producers.
        pending.extend((identity, dependency) for dependency in target.get("target_dependencies", []))
        for dependency in target.get("product_dependencies", []):
            add_product(dependency)
    return result


def stage_resources(products: Path, app: Path, manifest: dict) -> list[str]:
    required = required_bundles(manifest)
    missing = sorted(name for name in required if not (products / name).is_dir())
    if missing:
        raise ResourceStagingError("missing required resource bundles: " + ", ".join(missing))
    destination = app / "Contents" / "Resources"
    destination.mkdir(parents=True, exist_ok=True)
    for name in sorted(required):
        shutil.copytree(products / name, destination / name, dirs_exist_ok=True)
    return sorted(required)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--manifest", type=Path)
    source.add_argument("--package-root", type=Path)
    args = parser.parse_args()
    try:
        manifest = json.loads(args.manifest.read_text()) if args.manifest else resolved_manifest(args.package_root)
        names = stage_resources(args.products, args.app, manifest)
    except (ResourceStagingError, OSError, ValueError, KeyError) as error:
        parser.exit(1, f"resource staging failed: {error}\n")
    print(f"staged {len(names)} resource bundles")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
