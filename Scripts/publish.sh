#!/bin/bash
# Publish the DMG from Scripts/release.sh and keep only the newest GitHub release.
#
#   Scripts/publish.sh [--yes] [--dry-run]
#
# The repository must have an `origin` and `gh` must be authenticated. The tag
# v<version> must point at HEAD, and the DMG must already exist in
# .build/release. Publishing creates the release, verifies its asset, then
# deletes every older GitHub release. Git tags are kept: only releases (and
# their assets) are pruned.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(tr -d '[:space:]' < Sources/Sonovo/Resources/version.txt)
readonly VERSION
readonly TAG="v$VERSION"
readonly DMG=".build/release/Sonovo-$VERSION.dmg"

yes=no
dry_run=no
case "${1:-}" in
    "") ;;
    --yes) yes=yes ;;
    --dry-run) dry_run=yes ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "publish: usage: $0 [--yes] [--dry-run]" >&2; exit 2 ;;
esac

fail() { echo "publish: $*" >&2; exit 1; }
note() { echo "$*"; }

[[ -n "$VERSION" ]] || fail "version.txt is empty"
[[ -f "$DMG" ]] || fail "missing $DMG; run Scripts/release.sh first"
codesign --verify --strict "$DMG" || fail "the DMG signature does not verify"
verdict=$(spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1) \
    || fail "Gatekeeper rejected $DMG: $verdict"
grep -q 'source=Notarized Developer ID' <<<"$verdict" \
    || fail "the DMG is not notarised; run Scripts/release.sh, not --build-only"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "tag $TAG is missing"
[ "$(git rev-parse "$TAG^{commit}")" = "$(git rev-parse HEAD)" ] \
    || fail "tag $TAG does not point at HEAD"
command -v gh >/dev/null || fail "gh is not installed"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"
git remote get-url origin >/dev/null 2>&1 || fail "this repository has no origin"
repository=$(gh repo view --json nameWithOwner --jq .nameWithOwner) \
    || fail "cannot read the GitHub repository"

# Every release other than this tag. An empty list is normal for a first release.
releases=$(gh release list --limit 1000 --json tagName --jq '.[].tagName' 2>/dev/null || true)
others=$(printf '%s\n' "$releases" | grep -v -x -F "$TAG" | grep . || true)
sha=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

note "repository: $repository"
note "release:    $TAG"
note "asset:      $(basename "$DMG")"
note "sha256:     $sha"
if [ -n "$others" ]; then
    note "releases to delete after publishing:"
    printf '%s\n' "$others" | while IFS= read -r tag; do printf '  %s\n' "$tag"; done
else
    note "no older releases to delete"
fi

if [ "$dry_run" = yes ]; then
    note "publish: --dry-run, nothing was changed"
    exit 0
fi

if [ "$yes" != yes ]; then
    [ -t 0 ] || fail "not a terminal; pass --yes to publish without a prompt"
    printf 'Publish %s and delete older releases? [y/N] ' "$TAG"
    read -r answer
    [ "$answer" = y ] || { echo "publish: cancelled" >&2; exit 1; }
fi

if gh release view "$TAG" >/dev/null 2>&1; then
    note "release $TAG already exists; replacing its asset"
    gh release upload "$TAG" "$DMG" --clobber
else
    gh release create "$TAG" "$DMG" \
        --title "Sonovo $VERSION" \
        --generate-notes
fi

gh release view "$TAG" --json assets --jq '.assets[].name' \
    | grep -F -x -q "$(basename "$DMG")" \
    || fail "the release does not carry $(basename "$DMG")"

printf '%s\n' "$others" | while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    note "deleting release $tag (its tag is kept)"
    gh release delete "$tag" --yes || fail "could not delete release $tag"
done

remaining=$(gh release list --limit 1000 --json tagName --jq '.[].tagName')
[ "$remaining" = "$TAG" ] \
    || fail "expected only $TAG to remain; GitHub still lists: $(echo "$remaining" | tr '\n' ' ')"
latest=$(gh release list --limit 1000 --json tagName,isLatest --jq '.[] | select(.isLatest) | .tagName')
[ "$latest" = "$TAG" ] || fail "GitHub does not mark $TAG as the latest release"

note ""
note "published $TAG from $(git rev-parse --short HEAD) — only this release remains"
note "  asset  $(basename "$DMG")"
note "  sha256 $sha"
