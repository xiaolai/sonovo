#!/usr/bin/env bash
# Assemble an existing Debug build through the production resource manifest.
# This is a development preview; no tests, notarisation or publication runs.
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${1:-$HOME/Applications/Sonovo-dev.app}"
[[ "$destination" == *.app ]] || { echo "destination must be an .app" >&2; exit 2; }
if pgrep -f "$destination/Contents/MacOS/Sonovo" >/dev/null 2>&1; then
    echo "quit the running development app before replacing it: $destination" >&2
    exit 1
fi
stage="$PWD/.build/development-preview/Sonovo.app"
python3 - "$stage" "$destination" <<'PYGUARD'
from pathlib import Path
import sys
if Path(sys.argv[1]).resolve() == Path(sys.argv[2]).expanduser().resolve():
    raise SystemExit('development destination must differ from the staging directory')
PYGUARD
Scripts/package-app.sh --stage-only --skip-build --configuration debug "$stage"
plutil -replace NSHumanReadableCopyright -string "Development build" "$stage/Contents/Info.plist"
{
    echo "Sonovo development build; not a release artifact."
    echo "Source base commit: ${SONOVO_DEV_COMMIT:-unknown}"
    echo "The synchronized source may include uncommitted changes."
    echo "Built: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$stage/Contents/Resources/DevelopmentPreview.txt"
codesign --force --sign - --entitlements Scripts/Sonovo.entitlements "$stage" >/dev/null
codesign --verify --strict "$stage"
mkdir -p "$(dirname "$destination")"
if [[ -e "$destination" ]]; then
    # Only replace this caller-selected development output after staging and
    # signing have succeeded. Running bundles were refused above.
    python3 - "$destination" <<'PY'
from pathlib import Path
import shutil
import sys
path = Path(sys.argv[1])
if path.is_symlink() or path.suffix != '.app':
    raise SystemExit('refusing a symlink or non-app destination')
shutil.rmtree(path)
PY
fi
ditto "$stage" "$destination"
codesign --verify --strict "$destination"
echo "installed development preview: $destination"
