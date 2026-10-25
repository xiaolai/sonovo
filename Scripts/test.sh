#!/usr/bin/env bash
# Test, then prune stale build state so only the newest build survives.
# Arguments are passed through to `swift test`.
set -uo pipefail

cd "$(dirname "$0")/.."
python3 Scripts/check_design_tokens.py
token_status=$?
if [ "$token_status" -ne 0 ]; then
    python3 Scripts/clean_build_cache.py --quiet
    exit "$token_status"
fi

swift test "$@"
status=$?

python3 Scripts/clean_build_cache.py --quiet
cleanup_status=$?

if [ "$status" -ne 0 ]; then
    exit "$status"
fi
exit "$cleanup_status"
