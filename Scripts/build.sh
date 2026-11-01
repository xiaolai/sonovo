#!/usr/bin/env bash
# Build, then prune stale build state so only the newest build survives.
# Arguments are passed through to `swift build`.
set -uo pipefail

cd "$(dirname "$0")/.."
# Preserve the CLI spelling while also supplying an effective package target
# setting for Swift Build, whose PIF currently omits this -Xswiftc argument.
for argument in "$@"; do
    if [ "$argument" = "-warnings-as-errors" ]; then
        export SONOVO_WARNINGS_AS_ERRORS=1
    fi
done
python3 Scripts/check_design_tokens.py
token_status=$?
if [ "$token_status" -ne 0 ]; then
    python3 Scripts/clean_build_cache.py --quiet
    exit "$token_status"
fi

python3 Scripts/check_architecture.py
architecture_status=$?
if [ "$architecture_status" -ne 0 ]; then
    python3 Scripts/clean_build_cache.py --quiet
    exit "$architecture_status"
fi

swift build "$@"
status=$?

python3 Scripts/clean_build_cache.py --quiet
cleanup_status=$?

if [ "$status" -ne 0 ]; then
    exit "$status"
fi
exit "$cleanup_status"
