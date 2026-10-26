#!/usr/bin/env bash
# Build the release product and assemble Sonovo.app at the given path.
#
# Usage: Scripts/package-app.sh [destination]
# Default destination: /Applications/Sonovo.app
#
# The version comes from Sources/Sonovo/Resources/version.txt, so a release
# is one edit plus this script. The bundle is ad-hoc signed by default; set
# SONOVO_PACKAGE_SIGN=none when a caller (Scripts/release.sh) signs it later.
# It is not notarized and is not distributed through Homebrew here.
set -euo pipefail

cd "$(dirname "$0")/.."

destination="${1:-/Applications/Sonovo.app}"
version="$(tr -d '[:space:]' < Sources/Sonovo/Resources/version.txt)"
[[ -n "$version" ]] || { echo "version.txt is empty" >&2; exit 1; }

build_flags=(-c release)
if [ "${SONOVO_WARNINGS_AS_ERRORS:-0}" = 1 ]; then
    build_flags+=(-Xswiftc -warnings-as-errors)
fi
Scripts/build.sh "${build_flags[@]}"

products=".build/out/Products/Release"
binary="$products/Sonovo"
resources="$products/Sonovo_Sonovo.bundle"
math_resources="$products/SwiftMath_SwiftMath.bundle"
icon_source="Sources/Sonovo/Resources/AppIcon.png"
entitlements="Scripts/Sonovo.entitlements"
for required in "$binary" "$resources" "$math_resources" "$icon_source" "$entitlements"; do
    [[ -e "$required" ]] || { echo "missing $required" >&2; exit 1; }
done

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
app="$stage/Sonovo.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$binary" "$app/Contents/MacOS/Sonovo"
cp -R "$resources" "$app/Contents/Resources/"
cp -R "$math_resources" "$app/Contents/Resources/"
printf 'APPL????' > "$app/Contents/PkgInfo"

# SwiftMath's font bundle is resolved through Bundle.module from the app's
# resource directory, and its font loader force-unwraps the result. A bundle
# without the fonts would crash on the first formula, so fail the build.
math_fonts="$app/Contents/Resources/SwiftMath_SwiftMath.bundle/Contents/Resources/mathFonts.bundle"
[[ -d "$math_fonts" ]] || {
    echo "bundle is missing SwiftMath's mathFonts.bundle" >&2
    exit 1
}

# A bundle without the xterm-ghostty entry starts every shell with a
# database that does not exist; fail the build rather than ship it.
terminfo_entry="$app/Contents/Resources/Sonovo_Sonovo.bundle/Contents/Resources/terminfo/78/xterm-ghostty"
[[ -e "$terminfo_entry" ]] || {
    echo "bundle is missing the xterm-ghostty terminfo entry" >&2
    exit 1
}

# Mermaid is inlined into the diagram renderer; a missing or truncated script
# silently turns every diagram into a code block. Fail the build instead.
mermaid_script="$app/Contents/Resources/Sonovo_Sonovo.bundle/Contents/Resources/mermaid-12.2.0.min.js"
[[ -f "$mermaid_script" ]] || {
    echo "bundle is missing the Mermaid script" >&2
    exit 1
}
mermaid_bytes="$(wc -c < "$mermaid_script" | tr -d '[:space:]')"
[[ "$mermaid_bytes" -ge 5000000 ]] || {
    echo "Mermaid script looks truncated: $mermaid_bytes bytes" >&2
    exit 1
}

# The Graphviz and Markmap bundles are inlined the same way; a missing or
# truncated file would silently turn those fences into code blocks.
for diagram_engine in "viz-global-3.31.0.min.js:1000000" "markmap-0.18.12.min.js:500000"; do
    file_name="${diagram_engine%%:*}"
    minimum="${diagram_engine##*:}"
    diagram_script="$app/Contents/Resources/Sonovo_Sonovo.bundle/Contents/Resources/$file_name"
    [[ -f "$diagram_script" ]] || {
        echo "bundle is missing $file_name" >&2
        exit 1
    }
    diagram_bytes="$(wc -c < "$diagram_script" | tr -d '[:space:]')"
    [[ "$diagram_bytes" -ge "$minimum" ]] || {
        echo "$file_name looks truncated: $diagram_bytes bytes" >&2
        exit 1
    }
done

# The MDX compiler and its React runtime are inlined into the preview page;
# a missing or truncated file would silently disable every MDX preview.
for mdx_resource in \
    "mdx-compiler-3.1.1.js:600000" \
    "mdx-runtime-19.3.1.js:150000"; do
    file_name="${mdx_resource%%:*}"
    minimum="${mdx_resource##*:}"
    mdx_script="$app/Contents/Resources/Sonovo_Sonovo.bundle/Contents/Resources/$file_name"
    [[ -f "$mdx_script" ]] || {
        echo "bundle is missing $file_name" >&2
        exit 1
    }
    mdx_bytes="$(wc -c < "$mdx_script" | tr -d '[:space:]')"
    [[ "$mdx_bytes" -ge "$minimum" ]] || {
        echo "$file_name looks truncated: $mdx_bytes bytes" >&2
        exit 1
    }
done

# The compiler runs in its own process. Without the helper, every preview
# would report a configuration error instead of compiling, so fail the build.
helper_product="$products/SonovoMDXHelper"
[[ -x "$helper_product" ]] || {
    echo "missing $helper_product" >&2
    exit 1
}
mkdir -p "$app/Contents/Helpers"
cp "$helper_product" "$app/Contents/Helpers/SonovoMDXHelper"

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
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Local build</string>
    <key>NSMicrophoneUsageDescription</key><string>Sonovo records audio from the microphone you choose in System Settings.</string>
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

sign_mode="${SONOVO_PACKAGE_SIGN:-adhoc}"
case "$sign_mode" in
    adhoc|none) ;;
    *) echo "SONOVO_PACKAGE_SIGN must be adhoc or none" >&2; exit 2 ;;
esac
if [ "$sign_mode" = adhoc ]; then
    # Nested code is signed first; signing the app records the helper in its
    # seal, so a replaced helper fails verification.
    codesign --force --sign - --timestamp=none \
        "$app/Contents/Helpers/SonovoMDXHelper" > /dev/null
    codesign --force --sign - --timestamp=none \
        --entitlements "$entitlements" "$app" > /dev/null
    codesign --verify --strict "$app"
    audio_input_entitlement="$(
        codesign -d --entitlements - --xml "$app" 2>/dev/null \
            | plutil -extract 'com\.apple\.security\.device\.audio-input' \
                raw -expect bool -o - - 2>/dev/null
    )" || {
        echo "could not read the ad-hoc audio-input entitlement" >&2
        exit 1
    }
    if [ "$audio_input_entitlement" != "true" ]; then
        echo "ad-hoc signature does not enable the audio-input entitlement" >&2
        exit 1
    fi
fi

plutil -lint "$app/Contents/Info.plist" > /dev/null
microphone_usage="$(plutil -extract NSMicrophoneUsageDescription raw \
    "$app/Contents/Info.plist")" || {
    echo "Info.plist is missing NSMicrophoneUsageDescription" >&2
    exit 1
}
[[ -n "$microphone_usage" ]] || {
    echo "NSMicrophoneUsageDescription is empty" >&2
    exit 1
}
installed_version="$(plutil -extract CFBundleShortVersionString raw \
    "$app/Contents/Info.plist")"
[[ "$installed_version" == "$version" ]] || {
    echo "Info.plist version $installed_version != $version" >&2
    exit 1
}

mkdir -p "$(dirname "$destination")"
rm -rf "$destination"
ditto "$app" "$destination"
if [ "$sign_mode" = adhoc ]; then
    codesign --verify --strict "$destination"
fi
echo "installed $destination ($version)"
