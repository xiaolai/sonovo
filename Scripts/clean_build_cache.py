#!/usr/bin/env python3
"""Prune stale SwiftPM build state, keeping only the most recent build.

The rule: after a build or test, only the newest build state survives.

* `Products/Debug` and `Products/Release` are the latest build of each
  configuration and are never touched.
* Precompiled SDK modules: keep the newest copy of each module and remove
  copies written by earlier build sessions.
* Module caches and SDK stat caches: keep the two most recent sessions (one
  per configuration) and remove the rest.
* Temporary directories left by interrupted builds are removed.

Dependency checkouts, package repositories, build records, and intermediates
are incremental-build state, not copies of a build. Deleting them either
loses work or forces a full rebuild, so they stay.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / ".build" / "out"

# A precompiled module file ends with a session hash, for example
# `Foundation-1LW7UB94QLTSTJEZ1FDMTA3Q6.pcm`.
PCM_SUFFIX = re.compile(r"^(?P<module>.+)-[A-Z0-9]{20,32}\.pcm$")
TEMP_PREFIXES = ("swiftpm.tmp.", "swbuild.tmp.")
SESSION_DIRECTORIES = ("ModuleCache.noindex", "SDKStatCaches.noindex")


def format_bytes(count: int) -> str:
    value = float(count)
    for unit in ("B", "KB", "MB", "GB"):
        if value < 1024 or unit == "GB":
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} GB"


class Cleaner:
    def __init__(
        self,
        out: Path,
        dry_run: bool = False,
        keep_sessions: int = 2,
        quiet: bool = False
    ) -> None:
        self.out = out
        self.dry_run = dry_run
        self.keep_sessions = keep_sessions
        self.quiet = quiet
        self.removed_bytes = 0
        self.removed_count = 0
        self.failures: list[str] = []

    def _guard(self, path: Path) -> None:
        resolved = path.resolve()
        # `.build` itself may be scanned for temporary directories, so the
        # boundary is the build directory, not only its output folder.
        boundary = self.out.parent.resolve()
        if resolved == boundary or boundary not in resolved.parents:
            raise RuntimeError(
                f"refusing to remove outside the build output: {path}"
            )

    @staticmethod
    def size(path: Path) -> int:
        if path.is_symlink():
            return 0
        if path.is_file():
            try:
                return path.stat().st_size
            except OSError:
                return 0
        total = 0
        for root, _, files in os.walk(path):
            for name in files:
                try:
                    total += os.lstat(Path(root) / name).st_size
                except OSError:
                    continue
        return total

    def remove(self, path: Path) -> None:
        if not path.exists() and not path.is_symlink():
            return
        self._guard(path)
        size = self.size(path)
        display = path.relative_to(self.out.parent.parent)
        if self.dry_run:
            print(f"would remove {display} ({format_bytes(size)})")
        else:
            try:
                if path.is_dir() and not path.is_symlink():
                    shutil.rmtree(path)
                else:
                    path.unlink()
            except OSError as error:
                self.failures.append(f"{path}: {error}")
                print(f"cannot remove {path}: {error}", file=sys.stderr)
                return
            if not self.quiet:
                print(f"removed {display} ({format_bytes(size)})")
        self.removed_bytes += size
        self.removed_count += 1

    def prune_temporaries(self) -> None:
        for base in (self.out.parent, self.out):
            if not base.is_dir():
                continue
            for entry in sorted(base.iterdir()):
                if entry.name.startswith(TEMP_PREFIXES):
                    self.remove(entry)

    def prune_precompiled_modules(self) -> None:
        directory = self.out / "SDKExplicitPrecompiledModules"
        if not directory.is_dir():
            return

        groups: dict[tuple[Path, str], list[Path]] = {}
        for path in directory.rglob("*.pcm"):
            if not path.is_file() or path.is_symlink():
                continue
            match = PCM_SUFFIX.match(path.name)
            if not match:
                continue
            groups.setdefault(
                (path.parent, match.group("module")),
                []
            ).append(path)

        for files in groups.values():
            files.sort(
                key=lambda path: (path.stat().st_mtime, path.name),
                reverse=True
            )
            for stale in files[1:]:
                self.remove(stale)

    def prune_sessions(self) -> None:
        for name in SESSION_DIRECTORIES:
            directory = self.out / name
            if not directory.is_dir():
                continue
            sessions = [
                entry for entry in directory.iterdir()
                if entry.is_dir() and not entry.is_symlink()
            ]
            sessions.sort(
                key=lambda path: (path.stat().st_mtime, path.name),
                reverse=True
            )
            for stale in sessions[self.keep_sessions:]:
                self.remove(stale)

    def run(self) -> int:
        if not self.out.is_dir():
            print("no SwiftPM build output; nothing to clean")
            return 0
        self.prune_temporaries()
        self.prune_precompiled_modules()
        self.prune_sessions()
        verb = "would reclaim" if self.dry_run else "reclaimed"
        print(
            f"build cache {verb} {format_bytes(self.removed_bytes)} "
            f"across {self.removed_count} item(s)"
        )
        if self.failures:
            print(
                f"{len(self.failures)} item(s) could not be removed",
                file=sys.stderr
            )
            return 1
        return 0


def self_test() -> int:
    failures: list[str] = []

    def check(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    with tempfile.TemporaryDirectory() as temporary:
        build = Path(temporary) / "build"
        out = build / "out"
        products = out / "Products"
        debug = products / "Debug"
        release = products / "Release"
        debug.mkdir(parents=True)
        release.mkdir(parents=True)
        (debug / "Sonovo").write_text("debug")
        (release / "Sonovo").write_text("release")

        checkouts = build / "checkouts" / "package"
        checkouts.mkdir(parents=True)
        (checkouts / "source.swift").write_text("source")

        precompiled = out / "SDKExplicitPrecompiledModules"
        precompiled.mkdir()
        old = precompiled / "Foundation-AAAAAAAAAAAAAAAAAAAAAAAAAA.pcm"
        new = precompiled / "Foundation-BBBBBBBBBBBBBBBBBBBBBBBBBB.pcm"
        other = precompiled / "Swift-CCCCCCCCCCCCCCCCCCCCCCCCCC.pcm"
        for path, stamp in ((old, 1000), (new, 2000), (other, 1500)):
            path.write_text(path.name)
            os.utime(path, (stamp, stamp))

        module_cache = out / "ModuleCache.noindex"
        module_cache.mkdir()
        (module_cache / "modules.timestamp").write_text("keep me")
        for name, stamp in (("old", 1000), ("middle", 2000), ("new", 3000)):
            session = module_cache / name
            session.mkdir()
            (session / "cache").write_text(name)
            os.utime(session, (stamp, stamp))

        temporary_leftover = build / "swiftpm.tmp.ABC"
        temporary_leftover.mkdir()
        (temporary_leftover / "partial").write_text("partial")

        cleaner = Cleaner(out, keep_sessions=2, quiet=True)
        try:
            cleaner._guard(Path(temporary) / "outside")
        except RuntimeError:
            pass
        else:
            failures.append("guard accepted a path outside the build directory")
        status = cleaner.run()
        check(status == 0, f"cleaner exited {status}")
        check(not old.exists(), "older precompiled module was not removed")
        check(new.exists(), "newest precompiled module was removed")
        check(other.exists(), "unrelated precompiled module was removed")
        check(not (module_cache / "old").exists(), "oldest cache session remains")
        check((module_cache / "middle").exists(), "second cache session removed")
        check((module_cache / "new").exists(), "newest cache session removed")
        check(
            (module_cache / "modules.timestamp").exists(),
            "cache metadata was removed"
        )
        check(not temporary_leftover.exists(), "temporary directory remains")
        check((debug / "Sonovo").exists(), "debug product was removed")
        check((release / "Sonovo").exists(), "release product was removed")
        check(
            (checkouts / "source.swift").exists(),
            "dependency checkout was removed"
        )

    if failures:
        for message in failures:
            print(f"self-test: {message}", file=sys.stderr)
        return 1
    print("clean build cache self-test: pass")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Prune stale SwiftPM build state, keeping the most recent build."
        )
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="report what would be removed without deleting anything"
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="prove the pruner keeps the newest state and removes the rest"
    )
    parser.add_argument(
        "--keep-module-caches",
        type=int,
        default=2,
        help="number of recent module-cache sessions to keep (default: 2)"
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="print only the summary"
    )
    args = parser.parse_args()

    if args.keep_module_caches < 0:
        parser.error("--keep-module-caches must be zero or greater")
    if args.self_test:
        return self_test()

    return Cleaner(
        OUT,
        dry_run=args.dry_run,
        keep_sessions=args.keep_module_caches,
        quiet=args.quiet
    ).run()


if __name__ == "__main__":
    sys.exit(main())
