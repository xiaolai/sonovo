#!/bin/bash
# Build, sign, notarise, staple and package Sonovo as a disk image.
# Publishes nothing: the DMG is left in .build/release. To publish it and keep
# only the newest GitHub release, run Scripts/publish.sh afterwards.
#
#   Scripts/release.sh                 the ordinary release (clean tree and a v<version> tag required)
#   Scripts/release.sh --build-only    a Developer ID-signed DMG without notarisation, for local checks
#
# Environment:
#   SONOVO_SIGN_ID         optional; the Developer ID Application identity. Without it, exactly one
#                          Developer ID Application identity in the login keychain is used.
#   SONOVO_NOTARY_PROFILE  the notarytool keychain profile (default chase-notary). A name, never a credential.
#   SONOVO_E2E_HOST        optional; an E2E Mac's SSH name. When set, Gatekeeper assesses the DMG there too.
#
# The order is load-bearing, as in ../xdict's release.sh: the app is signed and notarised first,
# the DMG is built from the stapled app, and the DMG is signed, notarised and stapled in its own right.
set -euo pipefail
cd "$(dirname "$0")/.."

readonly ROOT=$PWD
readonly APP=$ROOT/.build/release/Sonovo.app
readonly OUT=$ROOT/.build/release
readonly ENTITLEMENTS=$ROOT/Scripts/Sonovo.entitlements
VERSION=$(tr -d '[:space:]' < Sources/Sonovo/Resources/version.txt)
readonly VERSION
readonly TRIES=5
readonly E2E_DIR=SonovoE2E/release

mode=release
case "${1:-}" in
    "") ;;
    --build-only) mode=build-only ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "release: usage: $0 [--build-only]" >&2; exit 2 ;;
esac

fail() { echo "release: $*" >&2; exit 1; }
note() { echo "$*"; }

[[ -n "$VERSION" ]] || fail "version.txt is empty"
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version.txt is not x.y.z: $VERSION"
[[ -f "$ENTITLEMENTS" ]] || fail "missing entitlements: $ENTITLEMENTS"

# The tree that is released must be the tree that was tested and named.
if [ "$mode" = release ]; then
    [ -z "$(git status --porcelain --untracked-files=normal)" ] \
        || fail "a release is cut from a committed tree; commit or stash first"
    git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null \
        || fail "tag v$VERSION is missing; tag the release commit first"
    [ "$(git rev-parse "v$VERSION^{commit}")" = "$(git rev-parse HEAD)" ] \
        || fail "tag v$VERSION does not point at HEAD"
else
    [ -z "$(git status --porcelain --untracked-files=normal)" ] \
        || note "release: --build-only with a dirty tree; this is not a releasable tree"
fi

# Signing identity: exactly one Developer ID Application certificate unless explicitly named.
identity="${SONOVO_SIGN_ID:-}"
if [ -z "$identity" ]; then
    identities=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p')
    count=$(printf '%s\n' "$identities" | grep -c . || true)
    [ "$count" -eq 1 ] \
        || fail "expected exactly one Developer ID Application identity, found $count"
    identity=$(printf '%s\n' "$identities" | head -1)
fi
security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$identity\"" \
    || fail "the signing identity is not in the login keychain: $identity"

profile="${SONOVO_NOTARY_PROFILE:-chase-notary}"
if [ "$mode" = release ]; then
    [[ -n "$profile" ]] || fail "SONOVO_NOTARY_PROFILE is empty"
    xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
        || fail "notarytool cannot use '$profile'; create it once with: xcrun notarytool store-credentials $profile"
fi

note "release: Sonovo $VERSION, $mode"
note "signing: $identity"
[ "$mode" = release ] && note "notary:  $profile (name only)"

# The same gates a developer runs, before anything is signed.
Scripts/check-design-tokens.sh
Scripts/test.sh

# package-app.sh assembles the bundle without signing it here. Strip before the Developer ID
# signature: release debug information can carry the builder's home path, and the signature
# must cover the final binary.
rm -rf "$OUT"
mkdir -p "$OUT"
SONOVO_PACKAGE_SIGN=none SONOVO_WARNINGS_AS_ERRORS=1 Scripts/package-app.sh "$APP"

strip -S -x "$APP/Contents/MacOS/Sonovo" || fail "strip failed"
[[ -x "$APP/Contents/MacOS/Sonovo" ]] || fail "the app binary is missing after strip"

# This machine's home path and internal hostnames must not ship. A third-party build path
# inside the prebuilt Ghostty static library is reported, not treated as this machine's data.
personal=$(grep -a -r -l -F -- "$HOME" "$APP" 2>/dev/null || true)
[ -z "$personal" ] || fail "the bundle contains this Mac's home path: $(echo "$personal" | head -3 | tr '\n' ' ')"
internal=$(grep -a -r -l -E 'MacMini-[0-9]+|legio\.internal|\.ts\.net' "$APP" 2>/dev/null || true)
[ -z "$internal" ] || fail "the bundle names an internal host: $(echo "$internal" | head -3 | tr '\n' ' ')"
upstream=$(grep -a -r -o -E '/Users/[A-Za-z0-9._-]+' "$APP/Contents/MacOS/Sonovo" 2>/dev/null \
    | sort -u | grep -v -F -- "$HOME" || true)
[ -z "$upstream" ] || note "release: known third-party build path in the binary: $(echo "$upstream" | tr '\n' ' ')"

# Developer ID and a secure timestamp. Only the app gets the hardened runtime and the
# microphone entitlement; a DMG is not an executable and needs neither.
sign_with_timestamp() {
    local artifact=$1 attempt runtime=$2
    local -a opts=()
    if [ "$runtime" = runtime ]; then
        opts=(--options runtime --entitlements "$ENTITLEMENTS")
    fi

    for (( attempt = 1; attempt <= TRIES; attempt++ )); do
        if [ "${#opts[@]}" -gt 0 ]; then
            if (( attempt == TRIES )); then
                codesign --force "${opts[@]}" --timestamp --sign "$identity" "$artifact" \
                    || fail "could not sign $artifact"
                return
            fi
            codesign --force "${opts[@]}" --timestamp --sign "$identity" "$artifact" >/dev/null 2>&1 \
                && return
        else
            if (( attempt == TRIES )); then
                codesign --force --timestamp --sign "$identity" "$artifact" \
                    || fail "could not sign $artifact"
                return
            fi
            codesign --force --timestamp --sign "$identity" "$artifact" >/dev/null 2>&1 \
                && return
        fi
        note "signing $(basename "$artifact") failed on attempt $attempt of $TRIES; retrying"
        sleep $(( attempt * 2 ))
    done
}

sign_with_timestamp "$APP" runtime
codesign --verify --strict --deep "$APP" || fail "the app signature does not verify"
described=$(codesign -dvvv "$APP" 2>&1 || true)
grep -q '^Authority=Developer ID Application:' <<<"$described" || fail "the app is not signed by a Developer ID Application identity"
grep -q '^TeamIdentifier=' <<<"$described" || fail "the app has no team identifier"
! grep -q '^TeamIdentifier=not set$' <<<"$described" || fail "the app has an ad-hoc signature, not a Developer ID"
grep -q 'flags=0x10000(runtime)' <<<"$described" || fail "the app is not signed with the hardened runtime"
grep -q '^Timestamp=' <<<"$described" || fail "the app is not signed with a secure timestamp"
audio_input_entitlement="$(
    codesign -d --entitlements - --xml "$APP" 2>/dev/null \
        | plutil -extract 'com\.apple\.security\.device\.audio-input' raw -expect bool -o - - 2>/dev/null
)" || fail "could not read the app's audio-input entitlement"
[ "$audio_input_entitlement" = "true" ] \
    || fail "the app does not enable the audio-input entitlement"
! grep -q 'get-task-allow' <<<"$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)" \
    || fail "get-task-allow is set; the notary would refuse it"

notarize() {  # $1: the file to submit
    local file=$1 attempt out id="" status
    for (( attempt = 1; attempt <= TRIES; attempt++ )); do
        if out=$(xcrun notarytool submit "$file" --keychain-profile "$profile" --output-format plist) \
           && id=$(plutil -extract id raw -o - - <<<"$out" 2>/dev/null); then
            break
        fi
        id=""
        (( attempt < TRIES )) || break
        note "upload attempt $attempt of $TRIES returned no submission id; retrying"
        sleep $(( attempt * 10 ))
    done
    [ -n "$id" ] || fail "could not upload $(basename "$file") for notarisation after $TRIES attempts"
    note "submitted $(basename "$file") as $id; waiting for Apple"
    for (( attempt = 1; attempt <= TRIES; attempt++ )); do
        out=$(xcrun notarytool wait "$id" --keychain-profile "$profile" --output-format plist) || true
        status=$(plutil -extract status raw -o - - <<<"$out" 2>/dev/null) || status=""
        case $status in Accepted | Invalid | Rejected) break ;; esac
        (( attempt < TRIES )) || break
        note "no verdict for $id yet (attempt $attempt of $TRIES); asking again"
        sleep $(( attempt * 15 ))
    done
    if [ "$status" != Accepted ]; then
        xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
        fail "notarisation of $(basename "$file") ended as '${status:-no verdict}' (submission $id)"
    fi
    note "notarised $(basename "$file") ($id)"
}

staple() {  # $1: artifact
    local attempt
    for (( attempt = 1; attempt <= TRIES; attempt++ )); do
        xcrun stapler staple "$1" >/dev/null 2>&1 && break
        (( attempt < TRIES )) || fail "could not staple a ticket to $1 after $TRIES attempts"
        note "stapling $(basename "$1") failed (attempt $attempt of $TRIES); retrying"
        sleep 10
    done
    xcrun stapler validate "$1" >/dev/null || fail "$1 has no valid ticket after stapling"
}

gatekeeper() {  # $1: artifact; the rest: spctl options
    local artifact=$1 verdict
    shift
    verdict=$(spctl -a -vv "$@" "$artifact" 2>&1) || fail "Gatekeeper rejected $artifact: $verdict"
    grep -q 'source=Notarized Developer ID' <<<"$verdict" \
        || fail "Gatekeeper accepted $artifact, but not as notarised: $verdict"
    note "Gatekeeper here: $(basename "$artifact") accepted, source=Notarized Developer ID"
}

if [ "$mode" = release ]; then
    zip=$OUT/Sonovo.zip
    ditto -c -k --keepParent "$APP" "$zip"
    notarize "$zip"
    rm -f "$zip"
    staple "$APP"
    codesign --verify --strict --deep "$APP" || fail "stapling broke the app's signature"
fi

dmg=$OUT/Sonovo-$VERSION.dmg
staging=$(mktemp -d)
mount=""
cleanup() {
    if [ -n "$mount" ]; then hdiutil detach -quiet "$mount" 2>/dev/null || true; rmdir "$mount" 2>/dev/null || true; fi
    rm -rf "$staging"
}
trap cleanup EXIT
ditto "$APP" "$staging/Sonovo.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "Sonovo $VERSION" -srcfolder "$staging" -ov -format UDZO "$dmg" \
    || fail "hdiutil could not build $dmg"

sign_with_timestamp "$dmg" ""
codesign --verify --strict "$dmg" || fail "the DMG signature does not verify"

if [ "$mode" = release ]; then
    notarize "$dmg"
    staple "$dmg"
    gatekeeper "$dmg" -t open --context context:primary-signature
    mount=$(mktemp -d)
    hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount" "$dmg" \
        || fail "could not mount $dmg to check it"
    codesign --verify --strict --deep "$mount/Sonovo.app" \
        || fail "the app inside $(basename "$dmg") does not verify"
    xcrun stapler validate "$mount/Sonovo.app" >/dev/null \
        || fail "the app inside $(basename "$dmg") carries no ticket"
    gatekeeper "$mount/Sonovo.app" -t exec
    hdiutil detach -quiet "$mount" || fail "could not detach $mount"
    rmdir "$mount" 2>/dev/null || true
    mount=""

    if [ -n "${SONOVO_E2E_HOST:-}" ]; then
        ssh -o BatchMode=yes -o ConnectTimeout=15 "$SONOVO_E2E_HOST" "mkdir -p '$E2E_DIR'" \
            || fail "cannot reach the E2E Mac"
        rsync -a "$dmg" "$SONOVO_E2E_HOST:$E2E_DIR/" \
            || fail "could not copy $(basename "$dmg") to the E2E Mac"
        ssh -o BatchMode=yes -o ConnectTimeout=15 "$SONOVO_E2E_HOST" bash -s -- "$E2E_DIR/$(basename "$dmg")" <<'SH' \
            || fail "Gatekeeper on the E2E Mac did not accept the release"
set -euo pipefail
dmg="$HOME/$1"
mount=$(mktemp -d)
trap 'hdiutil detach -quiet "$mount" 2>/dev/null || true; rmdir "$mount" 2>/dev/null || true' EXIT
assess() {  # assess <label> <spctl options...> <path>
    local label=$1 verdict
    shift
    verdict=$(spctl -a -vv "$@" 2>&1) || { echo "E2E Mac: Gatekeeper rejected $label: $verdict" >&2; return 1; }
    grep -q 'source=Notarized Developer ID' <<<"$verdict" \
        || { echo "E2E Mac: $label accepted, not as notarised: $verdict" >&2; return 1; }
    echo "Gatekeeper on the E2E Mac: $label — $(tr '\n' ' ' <<<"$verdict")"
}
assess "the disk image" -t open --context context:primary-signature "$dmg"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount" "$dmg"
codesign --verify --strict --deep "$mount/Sonovo.app"
assess "the app inside it" -t exec "$mount/Sonovo.app"
SH
    fi
fi

note ""
note "released Sonovo $VERSION ($mode), source tree $(git rev-parse --short HEAD) — not published"
note "  $dmg"
note "  size   $(du -h "$dmg" | cut -f1)"
note "  sha256 $(shasum -a 256 "$dmg" | cut -d' ' -f1)"
