#!/bin/bash
# Creates or refreshes the notarytool keychain profile Sonovo releases use.
#
#   Scripts/notary-profile.sh [--profile NAME]
#
# The profile can disappear with the login keychain. This reads the owner's
# env file, prints names and team only, stores the credentials, and proves
# notarytool can use the result. It never prints a secret.
#
# Env file: SONOVO_NOTARY_ENV (default: <repo>/.env, then the workspace root)
# Keys: APPLE_ID, APP_SPECIFIC_PASSWORD or APPLE_PASSWORD,
#       TEAM_ID or APPLE_TEAM_ID (otherwise the Developer ID certificate team).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)

profile=${SONOVO_NOTARY_PROFILE:-chase-notary}
while [ $# -gt 0 ]; do
    case $1 in
        --profile) [ $# -ge 2 ] || { echo "notary-profile: --profile needs a name" >&2; exit 2; }
                   profile=$2; shift 2 ;;
        -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *) echo "notary-profile: usage: $0 [--profile NAME]" >&2; exit 2 ;;
    esac
done
[[ -n "$profile" ]] || { echo "notary-profile: profile name is empty" >&2; exit 2; }

fail() { echo "notary-profile: $*" >&2; exit 1; }
if [ -n "${SONOVO_NOTARY_ENV:-}" ]; then
    env_file=$SONOVO_NOTARY_ENV
elif [ -f "$root/.env" ]; then
    env_file=$root/.env
else
    env_file=$root/../.env
fi
[ -f "$env_file" ] || fail "no env file at $env_file (set SONOVO_NOTARY_ENV to point at one)"

set +u
set -a
# shellcheck disable=SC1090 # the path is chosen above, on purpose
. "$env_file"
set +a
set -u

names=$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/{printf "%s ", $1}' "$env_file")
pick() {
    local key
    for key in "$@"; do
        if [ -n "${!key:-}" ]; then printf '%s' "${!key}"; return 0; fi
    done
    return 1
}

apple_id=$(pick APPLE_ID) || fail "no APPLE_ID in $env_file (keys: $names)"
password=$(pick APP_SPECIFIC_PASSWORD APPLE_PASSWORD) \
    || fail "no APP_SPECIFIC_PASSWORD (or APPLE_PASSWORD) in $env_file (keys: $names)"
team=$(pick TEAM_ID APPLE_TEAM_ID) || team=""
if [ -z "$team" ]; then
    team=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*Developer ID Application: .* (\([A-Z0-9]*\)).*/\1/p' | head -1) || true
fi
[ -n "$team" ] || fail "no team id: TEAM_ID is not in $env_file and this Mac has no Developer ID Application certificate"

echo "profile:  $profile"
echo "apple id: ${apple_id%%@*}@… (hidden)"
echo "team:     $team"

if xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
    echo "notary-profile: $profile already works; refreshing it from $env_file"
fi

xcrun notarytool store-credentials "$profile" \
    --apple-id "$apple_id" --team-id "$team" --password "$password" >/dev/null
unset apple_id password

xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
    || fail "stored, but notarytool cannot use '$profile' — Apple refused or the keychain could not keep it"
echo "notary-profile: $profile ready"
