#!/usr/bin/env bash
# Build, then prune stale build state so only the newest build survives.
# Arguments are passed through to `swift build`.
set -uo pipefail

cd "$(dirname "$0")/.."
swift build "$@"
status=$?

python3 Scripts/clean_build_cache.py --quiet
cleanup_status=$?

if [ "$status" -ne 0 ]; then
    exit "$status"
fi
exit "$cleanup_status"
