#!/usr/bin/env bash
# Build the release product and assemble Sonovo.app at the given path.
#
# Usage: Scripts/package-app.sh [destination]
# Default destination: /Applications/Sonovo.app
#
# The version comes from Sources/Sonovo/Resources/version.txt, so a release
# is one edit plus this script. The bundle is ad-hoc signed; it is not
# notarized and is not distributed through Homebrew.
set -euo pipefail

cd "$(dirname "$0")/.."

destination="${1:-/Applications/Sonovo.app}"
version="$(tr -d '[:space:]' < Sources/Sonovo/Resources/version.txt)"
[[ -n "$version" ]] || { echo "version.txt is empty" >&2; exit 1; }

Scripts/build.sh -c release

products=".build/out/Products/Release"
binary="$products/Sonovo"
resources="$products/Sonovo_Sonovo.bundle"
icon_source="Sources/Sonovo/Resources/AppIcon.png"
for required in "$binary" "$resources" "$icon_source"; do
    [[ -e "$required" ]] || { echo "missing $required" >&2; exit 1; }
done

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
app="$stage/Sonovo.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$binary" "$app/Contents/MacOS/Sonovo"
cp -R "$resources" "$app/Contents/Resources/"
printf 'APPL????' > "$app/Contents/PkgInfo"

# A bundle without the xterm-ghostty entry starts every shell with a
# database that does not exist; fail the build rather than ship it.
terminfo_entry="$app/Contents/Resources/Sonovo_Sonovo.bundle/Contents/Resources/terminfo/78/xterm-ghostty"
[[ -e "$terminfo_entry" ]] || {
    echo "bundle is missing the xterm-ghostty terminfo entry" >&2
    exit 1
}

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>Sonovo</string>
    <key>CFBundleExecutable</key><string>Sonovo</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.lixiaolai.sonovo</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Sonovo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Local build</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

iconset="$stage/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$icon_source" \
        --out "$iconset/icon_${size}x${size}.png" > /dev/null
    sips -z "$double" "$double" "$icon_source" \
        --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

codesign --force --sign - --timestamp=none "$app" > /dev/null
codesign --verify --strict "$app"

plutil -lint "$app/Contents/Info.plist" > /dev/null
installed_version="$(plutil -extract CFBundleShortVersionString raw \
    "$app/Contents/Info.plist")"
[[ "$installed_version" == "$version" ]] || {
    echo "Info.plist version $installed_version != $version" >&2
    exit 1
}

mkdir -p "$(dirname "$destination")"
rm -rf "$destination"
ditto "$app" "$destination"
codesign --verify --strict "$destination"
echo "installed $destination ($version)"
